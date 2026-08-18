package main

/*
	workbench — the desktop app: this project's simulator and deal advisor in one window.

	A single-file (`-file`) consumer program alongside `sim.odin` and `analyse_deal.odin`, and the third
	front end onto the same libraries. What it adds is not analysis — it is a HOST: the UI is HTML and CSS
	rendered by Sciter (via the `odin-sciter` bindings, `-collection:sciter=`), and the work runs
	IN-PROCESS on a worker thread rather than as a subprocess.

	  just workbench            # build + run (exports SCITER_LIB so the engine is found)

	Why in-process and not "a GUI that shells out to sim.exe":
	  * the CPU-heavy work (DDS sampling, combo, the exports) gets the whole machine, with real
	    per-scenario progress and a cancel, rather than a pipe and a spinner;
	  * no temp files: `analyse` hands back the report as text and the card page as a string;
	  * one artifact to ship.

	The flag surface is NOT re-implemented here, which is the point of the argv indirection: the controls
	compose an argument list and hand it to the same parsers the command lines use —
	`cli.parse_args` (norn) for generation, `analyse.parse_args` for the advisor — so validation and every
	error message are shared with the terminal. `analyse.parse_args` is called with `allow_stdin = false`:
	a windowed process must never block reading a stdin nobody can type into.

	Threading, the one rule the engine imposes: every DOM call belongs to the engine's thread. The worker
	touches nothing but `post_callback` (two machine words), and anything bigger travels in the shared
	struct under `mutex` — see `odin-sciter/examples/worker_thread.odin`, whose shape this follows.

	Sciter is not a browser: no `display:flex`, no `display:grid`, no `vw`/`clamp()`. `ui/workbench.css`
	is written for its flow model from the start, and its header explains the traps. Hosting the norn CARD
	page (a browser page, flex/grid throughout) is a later stage — see the plan's `@media sciter` note.

	DDS lifecycle: `analyse.run` owns its own (it knows which boards need a solver), and the generate path
	inits only when `--dd` is on. One job runs at a time, so the two never overlap — DDS is not reentrant.
*/

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "core:testing"
import "core:thread"
import "core:time"

import "analyse"
import "bidding"
import "deal_solve"
import "norn:cli"
import "norn:combo"
import "norn:norn"
import sciter "sciter:."
import sa "sciter:sciter_app"
import "sim_hooks"
import "suit_book"

// The UI, compiled in. Two files rather than one so the CSS keeps its own syntax highlighting and its own
// header comment; they are stitched at startup by replacing the `/*CSS*/` marker, which is a token rather
// than a `%s` because CSS is full of `%`.
UI_HTML :: #load("ui/workbench.html", string)
UI_CSS :: #load("ui/workbench.css", string)
CSS_MARKER :: "/*CSS*/"

// What the worker's two words mean. The first is the message kind, the second its payload; anything that
// does not fit in a word (every message, in practice) lives in `App` under `mutex`.
PROGRESS :: uintptr(1) // lparam = percent done
TRANSCRIPT :: uintptr(2) // the transcript grew; redraw it
FINISHED :: uintptr(3) // lparam = 1 if cancelled, 0 if it ran to the end
FAILED :: uintptr(4) // the message is in `App.failure`

Job_Kind :: enum {
	Generate,
	Analyse,
}

// One unit of work, composed on the engine's thread and owned by the worker. `argv` is the base argument
// list; the generate path appends `-S <scenario> -o <path>` per scenario, which is what makes one job a
// batch. Both slices are cloned out of the DOM reads that produced them (rule 3: temp memory does not
// outlive the callback), and freed by `job_free` when the job ends.
Job :: struct {
	kind:      Job_Kind,
	argv:      []string,
	scenarios: []string, // generate only: the scenario names to run, in order
	out_dir:   string, // generate only
	ext:       string, // generate only: the output extension implied by the format
}

App :: struct {
	using host: sa.Host_Handler,
	window:     sa.Window,
	handler:    sa.Event_Handler,

	// The catalogue, straight from the bidding system. `selected` indexes it.
	scenarios:  []cli.Scenario,
	selected:   int,

	// Shared with the worker. `post_callback` says THAT something changed; the lock is what makes it safe
	// to read WHAT.
	mutex:      sync.Mutex,
	transcript: strings.Builder,
	failure:    string,

	// The one flag that travels the other way (engine thread -> worker). Atomic because the worker reads
	// it between scenarios and the UI writes it at most once per job.
	cancel:     bool,

	// Engine-thread only, so no lock.
	job:        Job,
	worker:     ^thread.Thread,
	running:    bool,
	allocator:  runtime.Allocator,
}

// ---------------------------------------------------------------------------------------------------
// The worker
//
// Runs on the worker thread. Nothing in here touches the engine except `post_callback`, and it leaves
// through exactly one terminal message on every path — a worker that returns silently leaves the UI
// showing a progress bar forever.

work :: proc(app: ^App) {
	switch app.job.kind {
	case .Generate:
		work_generate(app)
	case .Analyse:
		work_analyse(app)
	}
}

work_generate :: proc(app: ^App) {
	// The --dd hooks, shared with sim.odin (see the `sim_hooks` package). Built once per job: `cli`
	// borrows the maps for the length of each run.
	hooks := sim_hooks.make_hooks()
	defer sim_hooks.free_hooks(&hooks)

	dds_up := false
	defer if dds_up {
		deal_solve.shutdown()
	}

	total := len(app.job.scenarios)
	for name, i in app.job.scenarios {
		// Cancellation is cooperative and its granularity is ONE SCENARIO: `cli.run` takes no
		// cancellation token, so a run in flight finishes. A 48-deal scenario is short; a 100k one is
		// not, and that is the honest limit of this button.
		if sync.atomic_load(&app.cancel) {
			transcribe(app, fmt.tprintf("cancelled after %d of %d scenarios", i, total))
			sa.post_callback(app.window, FINISHED, 1)
			return
		}

		path, _ := filepath.join({app.job.out_dir, fmt.tprintf("%s%s", name, app.job.ext)}, context.temp_allocator)
		argv := make([dynamic]string, 0, len(app.job.argv) + 4, context.temp_allocator)
		append(&argv, ..app.job.argv)
		append(&argv, "-S", name, "-o", path)

		opts, ok, message := cli.parse_args(argv[:])
		if !ok {
			fail(app, fmt.tprintf("%s: %s", name, message))
			return
		}
		// Wire the consumer's hooks in exactly where `cli.main_program` does — behind the flag, so the
		// default generator path never touches a solver.
		if opts.dd {
			opts.dd_filters = hooks.filters
			opts.dd_annotators = hooks.annotators
			if !dds_up {
				deal_solve.init()
				dds_up = true
			}
		}

		run_ok, run_message := cli.run(bidding.registry, opts)
		if !run_ok {
			fail(app, fmt.tprintf("%s: %s", name, run_message))
			return
		}
		transcribe(app, fmt.tprintf("[%d/%d] %s -> %s", i + 1, total, name, path))
		sa.post_callback(app.window, PROGRESS, uintptr((i + 1) * 100 / max(total, 1)))
	}
	sa.post_callback(app.window, FINISHED, 0)
}

work_analyse :: proc(app: ^App) {
	args, err := analyse.parse_args(app.job.argv, allow_stdin = false)
	defer analyse.args_free(&args)
	if err != "" {
		fail(app, err)
		return
	}

	// The report is gathered into a local builder and appended in one go: `analyse.run` writes
	// progressively, and holding the shared lock for the whole run would block the engine's thread the
	// moment it tried to redraw. A single deal is seconds at worst, so there is nothing to stream.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	result := analyse.run(analyse.builder_sink(&b), &args)

	transcribe(app, strings.to_string(b))
	if result != .Ok {
		fail(app, fmt.tprintf("analysis ended with %v", result))
		return
	}
	sa.post_callback(app.window, PROGRESS, 100)
	sa.post_callback(app.window, FINISHED, 0)
}

// Append a line to the shared transcript and ask the engine's thread to redraw it. Worker-side.
transcribe :: proc(app: ^App, line: string) {
	sync.lock(&app.mutex)
	// The string crosses threads, so both sides have to agree on the allocator; a plain `main` leaves
	// `context.allocator` as the default heap on every thread, which is why the clone below is enough.
	strings.write_string(&app.transcript, line)
	strings.write_byte(&app.transcript, '\n')
	sync.unlock(&app.mutex)
	sa.post_callback(app.window, TRANSCRIPT)
}

// The failing exit: the message travels in the struct (two words cannot carry a string), and FAILED is
// this worker's terminal message. Worker-side.
fail :: proc(app: ^App, message: string) {
	sync.lock(&app.mutex)
	app.failure = strings.clone(message)
	sync.unlock(&app.mutex)
	sa.post_callback(app.window, FAILED)
}

// ---------------------------------------------------------------------------------------------------
// The engine thread
//
// One call per posted message, in the order they were posted, on the thread that owns the DOM.

on_posted :: proc(handler: ^sa.Host_Handler, posted: sa.Posted) {
	app := (^App)(handler)

	switch posted.wparam {
	case PROGRESS:
		set_progress(app, int(posted.lparam))

	case TRANSCRIPT:
		draw_transcript(app)

	case FAILED:
		sync.lock(&app.mutex)
		message := strings.clone(app.failure, context.temp_allocator)
		delete(app.failure)
		app.failure = ""
		sync.unlock(&app.mutex)

		set_status(app, fmt.tprintf("failed: %s", message))
		job_ended(app)

	case FINISHED:
		set_status(app, "cancelled" if posted.lparam == 1 else "done")
		draw_transcript(app)
		job_ended(app)
	}
}

// Reap the worker and re-enable the buttons. Joining here is instant: the terminal message is the last
// thing the worker sends, so by the time this runs it is on its way out.
job_ended :: proc(app: ^App) {
	if app.worker != nil {
		thread.join(app.worker)
		thread.destroy(app.worker)
		app.worker = nil
	}
	job_free(&app.job, app.allocator)
	sync.atomic_store(&app.cancel, false)
	app.running = false
	set_enabled(app, "#generate", true)
	set_enabled(app, "#analyse", true)
	set_enabled(app, "#cancel", false)
}

job_free :: proc(job: ^Job, allocator: runtime.Allocator) {
	for arg in job.argv {
		delete(arg, allocator)
	}
	delete(job.argv, allocator)
	for name in job.scenarios {
		delete(name, allocator)
	}
	delete(job.scenarios, allocator)
	delete(job.out_dir, allocator)
	job^ = {}
}

// Start a job. The argument lists are already cloned into `app.allocator` by the caller (they were read
// out of the DOM, whose strings are temp memory).
start_job :: proc(app: ^App, job: Job, status: string) {
	if app.running {
		return
	}
	app.job = job
	app.running = true
	set_progress(app, 0)
	set_status(app, status)
	set_enabled(app, "#generate", false)
	set_enabled(app, "#analyse", false)
	set_enabled(app, "#cancel", job.kind == .Generate)
	app.worker = thread.create_and_start_with_poly_data(app, work)
}

// ---------------------------------------------------------------------------------------------------
// Composing the two command lines
//
// The controls -> an argv slice. Everything about what a flag MEANS lives in the parser this hands the
// slice to; these procs only spell the flags.

generate_job :: proc(app: ^App) -> (job: Job, err: string) {
	count := read_text(app, "#count")
	if n, ok := strconv.parse_int(strings.trim_space(count)); !ok || n <= 0 {
		return {}, fmt.tprintf("deals: %q is not a positive number", count)
	}
	format := read_text(app, "#format")
	out_dir, dir_err := resolve_out_dir(strings.trim_space(read_text(app, "#outdir")))
	if dir_err != "" {
		return {}, dir_err
	}

	argv := make([dynamic]string, 0, 10, context.temp_allocator)
	append(&argv, "-n", strings.trim_space(count))
	append(&argv, "-f", format)
	if seed := strings.trim_space(read_text(app, "#seed")); seed != "" {
		if _, ok := strconv.parse_u64(seed); !ok {
			return {}, fmt.tprintf("seed: %q is not a number", seed)
		}
		append(&argv, "-s", seed)
	}
	if read_bool(app, "#dd") {
		append(&argv, "--dd")
	}
	if read_bool(app, "#fixed") {
		append(&argv, "--fixed-table")
	}

	// Which scenarios: the whole registry, or the one selected in the list.
	names := make([dynamic]string, 0, len(app.scenarios), context.temp_allocator)
	if read_bool(app, "#all") {
		for scenario in app.scenarios {
			append(&names, scenario.name)
		}
	} else {
		if app.selected < 0 || app.selected >= len(app.scenarios) {
			return {}, "pick a scenario in the list (or tick “every scenario”)"
		}
		append(&names, app.scenarios[app.selected].name)
	}

	return Job {
			kind = .Generate,
			argv = clone_strings(argv[:], app.allocator),
			scenarios = clone_strings(names[:], app.allocator),
			out_dir = strings.clone(out_dir, app.allocator),
			ext = extension_for(format),
		},
		""
}

analyse_job :: proc(app: ^App) -> (job: Job, err: string) {
	deal := strings.trim_space(read_text(app, "#deal"))
	if deal == "" {
		return {}, "paste a deal: a PBN tag, a bare N:..., a LIN record or a hand URL"
	}

	argv := make([dynamic]string, 0, 8, context.temp_allocator)
	if sample := strings.trim_space(read_text(app, "#sample")); sample != "" && sample != "0" {
		if n, ok := strconv.parse_int(sample); !ok || n < 0 {
			return {}, fmt.tprintf("sample: %q is not a number", sample)
		}
		append(&argv, "--sample", sample)
	}
	if contract := strings.trim_space(read_text(app, "#contract")); contract != "" {
		append(&argv, "--contract", contract)
	}
	if target := strings.trim_space(read_text(app, "#target")); target != "" && target != "0" {
		append(&argv, "--target", target)
	}
	// The deal goes last, as one argument: the parser's positional overflow. Quoting is not a concern
	// here (there is no shell), so the `-` hands of a two-hand deal arrive intact inside this one string.
	append(&argv, deal)

	return Job{kind = .Analyse, argv = clone_strings(argv[:], app.allocator)}, ""
}

// Settle the output directory before a single deal is generated: make it ABSOLUTE, and create it if it is
// not there. Returns the resolved directory (temp memory — the caller clones it into the job) or a message.
//
// Both halves earn their keep, because `norn:cli` writes the page only AFTER generating it
// (`cli.run` -> `write_output` -> `os.write_entire_file`, which does not create parents): a missing
// directory otherwise costs a full run per scenario and then reports `Not_Exist`, and a relative path
// silently resolves against the PROCESS's working directory — the odin-sims dir under `just`, but
// whatever Explorer felt like for a double-clicked exe. Neither is a thing to discover after a batch.
resolve_out_dir :: proc(typed: string) -> (dir: string, err: string) {
	if typed == "" {
		return "", "output dir: needed — the generated pages have to land somewhere"
	}

	absolute, abs_err := filepath.abs(typed, context.temp_allocator)
	if abs_err != nil {
		return "", fmt.tprintf("output dir: %q is not a usable path: %v", typed, abs_err)
	}
	if os.exists(absolute) {
		if !os.is_dir(absolute) {
			return "", fmt.tprintf("output dir: %s is a file, not a directory", absolute)
		}
		return absolute, ""
	}
	if mkerr := os.make_directory_all(absolute); mkerr != nil {
		return "", fmt.tprintf("output dir: could not create %s: %v", absolute, mkerr)
	}
	return absolute, ""
}

// The file extension a format implies, for the per-scenario output path.
extension_for :: proc(format: string) -> string {
	switch format {
	case "html-cards", "html-handviewer":
		return ".html"
	case "pbn":
		return ".pbn"
	}
	return ".txt"
}

clone_strings :: proc(items: []string, allocator: runtime.Allocator) -> []string {
	out := make([]string, len(items), allocator)
	for item, i in items {
		out[i] = strings.clone(item, allocator)
	}
	return out
}

// ---------------------------------------------------------------------------------------------------
// The document: reads, writes, and the one handler
//
// The model is the truth and the document is a projection of it — with one deliberate exception, the
// input controls, whose text IS the state the user is editing. Reading it back is not the model/DOM
// disagreement rule 1 warns about; storing a second copy of it would be.

find :: proc(app: ^App, selector: string) -> sa.Element {
	root := sa.root(app.window) or_else nil
	if root == nil {
		return nil
	}
	return sa.select_first(root, selector) or_else nil
}

// An input's text, as temp memory. Rule 4: `scoped_element_value` releases the Value at the end of this
// scope, so the string handed back is the caller's temp copy of it.
read_text :: proc(app: ^App, selector: string) -> string {
	element := find(app, selector)
	if element == nil {
		return ""
	}
	value, err := sa.scoped_element_value(element)
	if err != nil {
		return ""
	}
	text, terr := sa.value_to_string(&value, context.temp_allocator)
	if terr != nil {
		return ""
	}
	return text
}

read_bool :: proc(app: ^App, selector: string) -> bool {
	element := find(app, selector)
	if element == nil {
		return false
	}
	value, err := sa.scoped_element_value(element)
	if err != nil {
		return false
	}
	on, berr := sa.value_to_bool(&value)
	return berr == nil && on
}

set_text_at :: proc(app: ^App, selector: string, text: string) {
	if element := find(app, selector); element != nil {
		sa.set_text(element, text)
	}
}

// An input's VALUE, which is what `read_text` reads back and what the control shows — not its text, which
// for a widget is a different thing entirely.
set_input :: proc(app: ^App, selector: string, text: string) {
	element := find(app, selector)
	if element == nil {
		return
	}
	value := sa.value_from(text)
	defer sa.value_clear(&value)
	sa.set_element_value(element, &value)
}

// ---------------------------------------------------------------------------------------------------
// About
//
// A licence obligation, not a nicety. The Sciter engine's EULA (external/sciter/SCITER-ENGINE-EULA.md in
// the odin-sciter checkout) reads:
//
//   "Your application shall include link to Terra Informatica site in "About" dialog or similar place in
//    your application. Text of the link: This Application (or Component) uses Sciter Engine
//    (http://sciter.com/), copyright Terra Informatica Software, Inc."
//
// That wording lives in `ui/workbench.html`, VERBATIM, and must stay verbatim — it is quoted text, not a
// sentence to improve. odin-sciter's docs/deployment.md release checklist lists it as a ship blocker.
// The panel is also where the other components' credits belong (DDS, and the suit-combination table's
// provenance), since nothing else in this app has a place for them.

SCITER_SITE :: "https://sciter.com/"

// Show or hide the About panel. It REPLACES the working panes rather than floating over them — see the
// CSS note about out-of-flow elements collapsing.
show_about :: proc(app: ^App, shown: bool) {
	set_shown(app, "#about-panel", shown)
	set_shown(app, ".panes", !shown)
}

// Show/hide by INLINE `display`, not by the `hidden` attribute. `hidden` is a valueless HTML attribute, so
// `attribute()` reports it as "" — indistinguishable from absent, which is what `set_attribute(…, "")`
// leaves behind. That makes the state unreadable, and a toggle whose state cannot be read is a toggle that
// cannot be tested. `display` is a value either way, and the CSS keeps `.about { display: none }` so the
// panel is hidden before the host touches anything.
set_shown :: proc(app: ^App, selector: string, shown: bool) {
	if element := find(app, selector); element != nil {
		sa.set_style(element, "display", "block" if shown else "none")
	}
}

// Is the element currently hidden? Read rather than remembered, so the toggle cannot get out of step with
// what is on screen — and `style` reports the value in effect, which for an untouched `.panel-help` is the
// stylesheet's own `display: none`.
effective_display_is_hidden :: proc(app: ^App, selector: string) -> bool {
	element := find(app, selector)
	if element == nil {
		return false
	}
	value, err := sa.style(element, "display", context.temp_allocator)
	return err == nil && value == "none"
}

// ---------------------------------------------------------------------------------------------------
// The hint bar
//
// Every control in the document carries `title` (the engine's own hover tooltip, free) and `data-hint`
// (one sentence, shown here the moment the control is hovered or focused). The hint bar is the half that
// needs no waiting and works from the keyboard, which is what makes the UI answerable by someone who does
// not already know the flags.

// The hint of `element`, or of the nearest ancestor carrying one — a click lands on a `<label>` or a row's
// inner `<span>` as often as on the control itself. Bounded, like `row_index`.
hint_for :: proc(element: sa.Element) -> string {
	node := element
	for _ in 0 ..< 4 {
		if node == nil {
			break
		}
		if hint, err := sa.attribute(node, "data-hint", context.temp_allocator); err == nil && hint != "" {
			return hint
		}
		node = sa.parent(node) or_else nil
	}
	return ""
}

show_hint :: proc(app: ^App, text: string) {
	set_text_at(app, "#hint", text)
}

// Open the Terra Informatica site in the user's own browser. Done from the HOST rather than by letting
// the document navigate: a hyperlink inside a Sciter window would try to load the page INTO the window
// (there is no browser chrome here, and the CSP-less engine has no business fetching it), and the script
// route (`@env`'s `env.launch`) would mean granting the document SYSINFO/FILE_IO features this app
// otherwise does not need.
//
// Windows only for now, which is the platform this app is built and used on; elsewhere the URL is still
// displayed and selectable, which is what the EULA actually asks for.
open_sciter_site :: proc() {
	when ODIN_OS == .Windows {
		win.ShellExecuteW(
			nil,
			win.utf8_to_wstring("open"),
			win.utf8_to_wstring(SCITER_SITE),
			nil,
			nil,
			win.SW_SHOWNORMAL,
		)
	}
}

// What the output-directory field starts as: DEALS_OUTPUT_DIR when the environment names one (the same
// variable the `gen-all` recipes take their `w:/deals/` default from), else a directory that certainly
// exists. Returns the note to put in the transcript when it did NOT use what it was given.
default_out_dir :: proc(allocator := context.allocator) -> (dir: string, note: string) {
	return choose_out_dir(os.get_env("DEALS_OUTPUT_DIR", context.temp_allocator), allocator)
}

// The decision, separated from the environment so it can be tested: prefer `candidate`, but only if it is
// REACHABLE — `w:/deals/` is this project's convention and a perfectly good default on the machine that
// has the `w:` volume mounted, and a dead end on one that does not. Falling back beats pre-filling a path
// whose only future is an error message when the user presses generate.
//
// The fallback is the user's Documents directory, not the working directory: a double-clicked exe inherits
// whatever cwd the shell felt like, which is no place to write a folder of practice deals.
choose_out_dir :: proc(candidate: string, allocator := context.allocator) -> (dir: string, note: string) {
	if candidate != "" && path_is_reachable(candidate) {
		return strings.clone(candidate, allocator), ""
	}

	fallback: string
	if documents, err := os.user_documents_dir(context.temp_allocator); err == nil && documents != "" {
		joined, jerr := filepath.join({documents, "bridge-deals"}, allocator)
		if jerr == nil {
			fallback = joined
		}
	}
	if fallback == "" { 	// no Documents to be had: the working directory, spelled out
		if cwd, err := filepath.abs(".", allocator); err == nil {
			fallback = cwd
		} else {
			fallback = strings.clone(".", allocator)
		}
	}

	if candidate == "" {
		return fallback, ""
	}
	return fallback, fmt.tprintf("%s is not reachable (no such drive or folder above it) — using %s", candidate, fallback)
}

// Could this path be created? True when the path itself or ANY ancestor exists, which is what separates
// "a folder that is not there yet" (fine — `resolve_out_dir` creates it) from "a volume that is not
// mounted" (not fine, and no amount of creating will help).
path_is_reachable :: proc(path: string) -> bool {
	dir := path
	for dir != "" {
		if os.exists(dir) {
			return true
		}
		parent := filepath.dir(dir)
		if parent == dir { 	// reached the root and it does not exist
			return false
		}
		dir = parent
	}
	return false
}

set_status :: proc(app: ^App, text: string) {
	set_text_at(app, "#status", text)
}

// The fill's width in px, not %: the track is a fixed 200px (see the CSS), and the host knows that.
set_progress :: proc(app: ^App, percent: int) {
	if fill := find(app, "#fill"); fill != nil {
		sa.set_style(fill, "width", fmt.tprintf("%dpx", 2 * clamp(percent, 0, 100))) // 200px track
	}
}

set_enabled :: proc(app: ^App, selector: string, enabled: bool) {
	element := find(app, selector)
	if element == nil {
		return
	}
	// `set_attribute` with "" REMOVES the attribute, which is what enabling is; disabling needs any
	// non-empty value, since `disabled` is a presence flag rather than a value.
	sa.set_attribute(element, "disabled", "" if enabled else "true")
}

// Push the whole transcript into the report pane. `<plaintext>` publishes a SOM asset whose `content`
// property is writable (odin-sciter docs/BEHAVIORS.md), which is the route this takes; `set_text` is the
// fallback for an engine build where the asset is absent, so a missing widget interface would cost
// formatting rather than output.
//
// TWO measured facts about that widget, both from the test below:
//   * `sciter_app.text` CANNOT read a plaintext back — the behavior keeps its content in `<text>`
//     children of its own, and the element's own text is "". Read it through `asset_get("content")`.
//   * a TRAILING newline becomes an extra (empty) line the widget then reports at the FRONT of the
//     content, so the pane grows a blank first line. The transcript ends every line with `\n`, hence the
//     trim: the separator belongs between lines, not after the last one.
draw_transcript :: proc(app: ^App) {
	sync.lock(&app.mutex)
	text := strings.clone(strings.trim_right(strings.to_string(app.transcript), "\r\n"), context.temp_allocator)
	sync.unlock(&app.mutex)

	element := find(app, "#report")
	if element == nil {
		return
	}
	if asset, err := sa.element_asset(element, "plaintext"); err == nil {
		value := sa.value_from(text)
		defer sa.value_clear(&value)
		if sa.asset_set(asset, "content", &value) == nil {
			return
		}
	}
	sa.set_text(element, text)
}

// The report pane's content, as the widget reports it. The test's reader, and the reason `draw_transcript`
// documents what it does: this is the only way to see what is actually on screen.
report_content :: proc(app: ^App, allocator := context.allocator) -> (text: string, ok: bool) {
	element := find(app, "#report")
	if element == nil {
		return "", false
	}
	asset, aerr := sa.element_asset(element, "plaintext")
	if aerr != nil {
		return "", false
	}
	value, gerr := sa.asset_get(asset, "content")
	if gerr != nil {
		return "", false
	}
	defer sa.value_clear(&value)
	s, serr := sa.value_to_string(&value, allocator)
	return s, serr == nil
}

// The scenario list, from the registry. One row per scenario carrying its index — the attribute is part
// of the projection this code emitted, not state the document keeps on the model's behalf.
draw_scenarios :: proc(app: ^App) {
	list := find(app, "#scenarios")
	if list == nil {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	for scenario, i in app.scenarios {
		fmt.sbprintf(
			&b,
			`<div class="row %s" data-index="%d"><span class="name">%s</span><span class="title">%s</span></div>`,
			"sel" if i == app.selected else "",
			i,
			escape_html(scenario.name, context.temp_allocator),
			escape_html(cli.scenario_title(scenario), context.temp_allocator),
		)
	}
	sa.set_html(list, strings.to_string(b))
}

// `set_html` is a parser, so anything that reaches it is escaped first. The scenario names are ours, but
// the rule does not have exceptions — that is what makes it a rule and not a judgement call.
escape_html :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for r in s {
		switch r {
		case '&':
			strings.write_string(&b, "&amp;")
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case '"':
			strings.write_string(&b, "&quot;")
		case:
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

// One handler on the window rather than one per control: `draw_scenarios` replaces the rows on every
// change, and a handler attached to a row would go with them.
//
// Three groups arrive here. `.BEHAVIOR_EVENT` is the clicks; `.MOUSE` and `.FOCUS` exist only to drive the
// hint bar, and they are why the subscription is not just the first one.
on_event :: proc(handler: ^sa.Event_Handler, event: sa.Event) -> bool {
	app := (^App)(handler.user_data)

	// The hint bar, from whatever the pointer or the keyboard is on. Reading it from the DOM is right: the
	// text is authored in the document beside the control it describes, so there is no table here to fall
	// out of step with the markup. Never claims the event — hovering must not stop being a hover.
	if me, ok := sa.mouse_event(event); ok && me.phase == .Bubbling {
		switch me.code {
		case .MOUSE_ENTER:
			show_hint(app, hint_for(me.target))
		case .MOUSE_LEAVE:
			show_hint(app, "")
		case .MOUSE_MOVE, .MOUSE_UP, .MOUSE_DOWN, .MOUSE_DCLICK, .MOUSE_WHEEL, .MOUSE_TICK, .MOUSE_IDLE,
		     .DROP, .DRAG_ENTER, .DRAG_LEAVE, .DRAG_REQUEST, .MOUSE_TCLICK, .MOUSE_DRAG_REQUEST,
		     .MOUSE_CLICK, .DRAGGING, .MOUSE_HIT_TEST:
		// not ours; a `case:` would swallow application codes (gotchas #10)
		}
		return false
	}
	// Keyboard users get the same help: tabbing onto a control shows its hint.
	if fe, ok := sa.focus_event(event); ok && fe.phase == .Bubbling {
		if fe.code == .GOT {
			show_hint(app, hint_for(fe.target))
		}
		return false
	}

	be, ok := sa.behavior_event(event)
	if !ok || be.phase != .Bubbling {
		return false
	}
	// A `<button>` raises `.BUTTON_CLICK`; an `<a href>` raises `.HYPERLINK_CLICK` instead, and returning
	// true from it is also what stops the engine trying to navigate THIS window to the href.
	if be.code != .BUTTON_CLICK && be.code != .HYPERLINK_CLICK {
		return false
	}

	id, _ := sa.attribute(be.target, "id", context.temp_allocator)
	switch id {
	case "generate":
		job, err := generate_job(app)
		if err != "" {
			set_status(app, err)
			return true
		}
		start_job(
			app,
			job,
			fmt.tprintf("generating %d scenario%s…", len(job.scenarios), "" if len(job.scenarios) == 1 else "s"),
		)
		return true

	case "analyse":
		job, err := analyse_job(app)
		if err != "" {
			set_status(app, err)
			return true
		}
		start_job(app, job, "analysing…")
		return true

	case "cancel":
		// Asks rather than stops: the worker notices at its next scenario boundary and the UI learns of
		// it when FINISHED arrives with a 1. Waiting for the message rather than for the thread is what
		// keeps the pump running — and drawing — while the job winds down.
		sync.atomic_store(&app.cancel, true)
		set_status(app, "cancelling after this scenario…")
		return true

	case "clear":
		sync.lock(&app.mutex)
		strings.builder_reset(&app.transcript)
		sync.unlock(&app.mutex)
		draw_transcript(app)
		set_status(app, "idle")
		return true

	case "help-generate", "help-analyse":
		// The `?` next to a panel legend toggles that panel's paragraph. The button's id names the block
		// (`help-generate` -> `#help-generate-text`), so adding a third panel needs no code here.
		selector := fmt.tprintf("#%s-text", id)
		set_shown(app, selector, effective_display_is_hidden(app, selector))
		return true

	case "about":
		show_about(app, true)
		return true

	case "about-close":
		show_about(app, false)
		return true

	case "about-sciter-link":
		// The EULA's link. Handled here so the click opens the system browser instead of navigating this
		// window (see open_sciter_site).
		open_sciter_site()
		return true
	}

	// Not a button: a scenario row. The click may land on one of the row's own spans, so walk up looking
	// for the `data-index` the render wrote. (The bindings have no `closest`; `parent` is the primitive.)
	if index, is_row := row_index(be.target); is_row {
		app.selected = index
		draw_scenarios(app)
		return true
	}
	return false
}

// The scenario index a clicked element belongs to: itself, or the nearest ancestor carrying `data-index`.
// Bounded rather than a `for` over the whole ancestry — the rows are two levels deep and an unbounded
// walk would reach the document root on every click that hits neither.
row_index :: proc(element: sa.Element) -> (index: int, ok: bool) {
	node := element
	for _ in 0 ..< 4 {
		if node == nil {
			break
		}
		if raw, err := sa.attribute(node, "data-index", context.temp_allocator); err == nil && raw != "" {
			return strconv.parse_int(raw)
		}
		node = sa.parent(node) or_else nil
	}
	return 0, false
}

// ---------------------------------------------------------------------------------------------------

main :: proc() {
	// The engine is a shared library found at run time, not linked: `load_engine` prints every path it
	// tried, and the two ways out, if it is not there. `just workbench` exports SCITER_LIB for it.
	if !sa.load_engine() {
		os.exit(1)
	}
	if err := sa.init(); err != nil { 	// argc/argv, and the debug output (silent CSS errors otherwise)
		fmt.eprintln("could not initialise the engine:", err)
		os.exit(1)
	}
	defer sa.shutdown()

	// combo is engine-only until this project's published suit-combination table is registered, exactly
	// as in sim.odin and analyse_deal.odin. `combo.shutdown` also frees its worker pool and the table's
	// key index.
	defer combo.shutdown()
	combo.set_suit_book(suit_book.provider())

	// `.ENABLE_DEBUG` is what lets the SDK's inspector attach — a development affordance, and odin-sciter's
	// release checklist (docs/deployment.md) says not to ship it. `just workbench-debug` is the build that
	// has it; `-o:speed` does not. `.MAIN` is the flag that makes closing the window end the message pump.
	flags: sciter.Sciter_Create_Window_Flags = {.MAIN}
	when ODIN_DEBUG {
		flags |= {.ENABLE_DEBUG}
	}
	window, werr := sa.create_window({width = 1120, height = 780, flags = flags})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}

	// On the heap, because the engine stores this address for as long as the window lives — and installed
	// BEFORE the document loads, as `set_host_handler` asks.
	app := new(App)
	app.window = window
	app.on_posted = on_posted
	app.allocator = context.allocator
	app.scenarios = bidding.registry
	app.selected = 0
	app.transcript = strings.builder_make()
	sa.set_host_handler(window, app)

	if err := sa.load_html(window, compose_document(context.temp_allocator), "about:blank"); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	// `.MOUSE` and `.FOCUS` are here for the hint bar; without them the clicks still work and the hint bar
	// stays permanently empty, which is a silent failure worth knowing the shape of.
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS},
		on_event     = on_event,
		user_data    = app,
	}
	sa.attach_window_handler(window, &app.handler)

	// Pre-fill the output directory so the field is never a blank the user has to guess at, and so the
	// destination is VISIBLE before a batch rather than inferred afterwards: DEALS_OUTPUT_DIR when set (the
	// justfile exports the same `w:/deals/` default the `gen-all` recipes use), else this process's working
	// directory, spelled absolutely — the exact thing a relative path would have resolved against.
	out_dir, out_note := default_out_dir(context.temp_allocator)
	set_input(app, "#outdir", out_dir)

	engine := sa.version()
	engine_text := fmt.tprintf("sciter %d.%d.%d.%d", engine[0], engine[1], engine[2], engine[3])
	set_text_at(app, "#engine", fmt.tprintf("%d scenarios · %s", len(app.scenarios), engine_text))

	// The About panel's dynamic lines. The static ones — the Sciter attribution above all — are in the
	// document, where they cannot be reworded by a format string.
	set_text_at(
		app,
		"#about-versions",
		fmt.tprintf("%s · %d scenarios · Odin %s", engine_text, len(app.scenarios), ODIN_VERSION),
	)
	set_text_at(
		app,
		"#about-book",
		"Suit-combination tables in the card-page analysis are baked from the BridgeHands suit-combination pages; the lines and percentages are facts of the game, the wording and arrangement are theirs.",
	)
	draw_scenarios(app)
	transcribe_local(
		app,
		"Pick a scenario and press generate, or paste a deal below and press analyse. Everything runs in this process.",
	)
	if out_note != "" {
		// Said once, at startup, rather than discovered when a batch fails: the field shows a directory the
		// user did not ask for, and silently substituting one is worse than naming it.
		transcribe_local(app, out_note)
	}

	sa.show(window)
	sa.run() // returns when the window closes

	// A job still in flight when the window closed: ask it to stop, then wait. Nothing draws after this
	// (the pump has stopped) and the transcript is about to go, so there is nothing to report.
	if app.worker != nil {
		sync.atomic_store(&app.cancel, true)
		thread.join(app.worker)
		thread.destroy(app.worker)
		app.worker = nil
	}
	job_free(&app.job, app.allocator)
	strings.builder_destroy(&app.transcript)
	free(app)
}

// The document, with the stylesheet spliced into its `/*CSS*/` marker. A `#load`ed constant cannot be
// sliced at a run-time index, hence the local copy.
compose_document :: proc(allocator := context.allocator) -> string {
	html := string(UI_HTML)
	marker := strings.index(html, CSS_MARKER)
	if marker < 0 {
		return html // no marker: the document is still valid, just unstyled
	}
	return strings.concatenate({html[:marker], string(UI_CSS), html[marker + len(CSS_MARKER):]}, allocator)
}

// `transcribe` without the cross-thread message: for the engine thread, before any worker exists.
transcribe_local :: proc(app: ^App, line: string) {
	strings.write_string(&app.transcript, line)
	strings.write_byte(&app.transcript, '\n')
	draw_transcript(app)
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// A WINDOWLESS view rather than a window: it needs no visible desktop, and it is how odin-sciter's own
// examples test a document. What these pin is the seam between the document and the host — the ids the
// host reads, and that the argv its controls compose is ACCEPTED BY THE REAL PARSERS. That last one is
// the point of composing an argv at all: a flag misspelled here would otherwise surface as a runtime
// "unknown flag" in the transcript, and only once someone pressed the button.
//
// The analysis itself is not retested here; `analyse`'s own tests and `test-golden` cover it.

@(private = "file")
g_view: sa.Windowless_View

// Bring up the engine, the view and one loaded document, and hand back an App wired to it. Returns false
// when there is no engine to test against, which is a skip rather than a failure.
@(private = "file")
test_app :: proc(t: ^testing.T, app: ^App) -> (ok: bool) {
	if !sa.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}
	// A test binary reaches the engine without going through the application's `init`, so it installs the
	// debug output itself: on Windows a CSS warning with no handler installed arrives as an exception,
	// which the test runner treats as fatal.
	sa.set_default_debug_output()

	if g_view.window == nil {
		// The engine keeps the view for the life of the process, so it is not the tracking allocator's
		// business — otherwise every later test reports it as a leak.
		context.allocator = runtime.default_allocator()
		v, err := sa.create_windowless({width = 1120, height = 780})
		testing.expect_value(t, err, nil)
		if v.window == nil {
			return false
		}
		g_view = v
	}

	testing.expect_value(t, sa.load_html(g_view.window, compose_document(context.temp_allocator), "about:blank"), nil)
	pump_view()

	app.window = g_view.window
	app.allocator = context.allocator
	app.scenarios = bidding.registry
	app.selected = 0
	app.transcript = strings.builder_make()
	return true
}

// Run the engine over the view: layout, style resolution and the behavior attachment that depends on it.
@(private = "file")
pump_view :: proc() {
	for i in 0 ..< 8 {
		sa.windowless_heartbeat(&g_view, time.Duration(i) * 16 * time.Millisecond)
		sa.paint_windowless(&g_view)
	}
}

@(private = "file")
pump :: proc(app: ^App) {
	pump_view()
}

@(private = "file")
test_app_destroy :: proc(app: ^App) {
	strings.builder_destroy(&app.transcript)
	job_free(&app.job, app.allocator)
}

// Set an input's text the way a person typing into it would leave it.
@(private = "file")
type_into :: proc(app: ^App, selector: string, text: string) {
	element := find(app, selector)
	if element == nil {
		return
	}
	value := sa.value_from(text)
	defer sa.value_clear(&value)
	sa.set_element_value(element, &value)
}

@(private = "file")
tick :: proc(app: ^App, selector: string) {
	element := find(app, selector)
	if element == nil {
		return
	}
	value := sa.value_from(true)
	defer sa.value_clear(&value)
	sa.set_element_value(element, &value)
}

// The stylesheet is spliced in, and the marker does not survive into the document.
//
// It also guards against browser idioms Sciter does not implement — but only in CODE: the comments in
// both UI files DISCUSS `display:flex`, `grid` and `clamp()` (that is what they are warning about), so a
// naive substring search over the whole document matches its own documentation. Stripping the comments
// first is the difference between a test of the stylesheet and a test of the prose.
@(test)
test_compose_document_splices_the_stylesheet :: proc(t: ^testing.T) {
	document := compose_document(context.temp_allocator)
	testing.expect(t, !strings.contains(document, CSS_MARKER), "the marker must be consumed")
	testing.expect(t, strings.contains(document, "flow: vertical"), "the CSS must be present")
	testing.expect(t, strings.contains(document, `id="report"`), "the HTML must be present")

	code := strip_css_comments(document, context.temp_allocator)
	for idiom in ([]string{"display: flex", "display:flex", "display: grid", "display:grid", "clamp(", "vw;", "vh;"}) {
		testing.expectf(
			t,
			!strings.contains(code, idiom),
			"Sciter does not implement %q — see ui/workbench.css",
			idiom,
		)
	}
}

// Everything between `/*` and `*/`, removed. Only used by the test above.
@(private = "file")
strip_css_comments :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	rest := s
	for {
		open := strings.index(rest, "/*")
		if open < 0 {
			strings.write_string(&b, rest)
			break
		}
		strings.write_string(&b, rest[:open])
		close := strings.index(rest[open:], "*/")
		if close < 0 {
			break // unterminated: the remainder is all comment
		}
		rest = rest[open + close + 2:]
	}
	return strings.to_string(b)
}

// The Sciter EULA's attribution, VERBATIM, in the About panel — a ship blocker on odin-sciter's release
// checklist, and the kind of text an editing pass "improves" without knowing it is quoted. The engine's
// own EULA states the required sentence; this asserts the document still carries it, and that a link to
// the site is there for the host to handle.
@(test)
test_the_about_panel_carries_the_sciter_attribution :: proc(t: ^testing.T) {
	document := compose_document(context.temp_allocator)
	required :: "This Application"
	site :: "http://sciter.com/"

	testing.expect(
		t,
		strings.contains(document, "uses Sciter Engine"),
		"the EULA's attribution sentence must appear in the About panel, verbatim",
	)
	testing.expect(t, strings.contains(document, required))
	testing.expect(t, strings.contains(document, "copyright Terra Informatica Software, Inc."))
	testing.expect(t, strings.contains(document, site), "and it must be a link to the site")
	testing.expect(t, strings.contains(document, `id="about-sciter-link"`), "which the host opens")
}

// The About panel is reachable and closable, and showing it hides the working panes rather than floating
// over them (an overlay would hit Sciter's 1px collapse — see the CSS).
@(test)
test_the_about_panel_toggles :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// `style` reports the value in EFFECT, not only an inline one, so the stylesheet's own
	// `.about { display: none }` is what this reads before the host has touched anything.
	testing.expect_value(t, effective_display(&app, "#about-panel"), "none")

	show_about(&app, true)
	testing.expect_value(t, effective_display(&app, "#about-panel"), "block")
	testing.expect_value(t, effective_display(&app, ".panes"), "none") // the panes give way to it

	show_about(&app, false)
	testing.expect_value(t, effective_display(&app, "#about-panel"), "none")
	testing.expect_value(t, effective_display(&app, ".panes"), "block")
}

// An element's `display` as the engine has it — the stylesheet's value until the host sets an inline one.
@(private = "file")
effective_display :: proc(app: ^App, selector: string) -> string {
	element := find(app, selector)
	if element == nil {
		return "<missing>"
	}
	value, err := sa.style(element, "display", context.temp_allocator)
	if err != nil {
		return "<error>"
	}
	return value
}

// Every id the host reads or writes has to exist in the document. A rename on either side is otherwise
// silent: `find` returns nil, `read_text` returns "", and a control simply stops working.
@(test)
test_the_document_carries_every_control_the_host_touches :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	for selector in ([]string{"#engine", "#scenarios", "#count", "#format", "#seed", "#outdir", "#dd", "#fixed", "#all", "#generate", "#cancel", "#fill", "#status", "#deal", "#sample", "#contract", "#target", "#analyse", "#clear", "#report", ".panes", "#about", "#about-panel", "#about-close", "#about-sciter-link", "#about-versions", "#about-book"}) {
		testing.expectf(t, find(&app, selector) != nil, "the document is missing %s", selector)
	}
}

// The pre-filled output directory has to be somewhere that can actually be written. `w:/deals/` is this
// project's convention and the justfile exports it, so the field would otherwise open showing a dead path
// on any machine without that volume — and the user would only find out when a batch refused.
@(test)
test_the_default_output_dir_falls_back_when_unreachable :: proc(t: ^testing.T) {
	// A folder that does not exist yet, under a drive that does, is REACHABLE: resolve_out_dir creates it.
	testing.expect(t, path_is_reachable("target/debug/not-there-yet/deeper"))
	testing.expect(t, path_is_reachable("."))

	// A drive letter nothing is mounted on is not, and no amount of creating would help.
	unreachable_path :: "zz:/deals"
	testing.expect(t, !path_is_reachable(unreachable_path))

	chosen, note := choose_out_dir(unreachable_path, context.temp_allocator)
	testing.expect(t, chosen != unreachable_path, "an unreachable candidate must not be offered")
	testing.expect(t, path_is_reachable(chosen), chosen)
	testing.expect(t, strings.contains(note, unreachable_path), note) // says what it rejected
	testing.expect(t, strings.contains(note, chosen), note) // and what it used instead

	// A reachable candidate is taken as given, with nothing to report.
	kept, quiet := choose_out_dir("target/debug", context.temp_allocator)
	testing.expect_value(t, kept, "target/debug")
	testing.expect_value(t, quiet, "")

	// No candidate at all: a real directory, and no note — the user was not overridden, just defaulted.
	empty, silent := choose_out_dir("", context.temp_allocator)
	testing.expect(t, path_is_reachable(empty), empty)
	testing.expect_value(t, silent, "")
}

// The document is decoded as UTF-8. Without a `<meta charset>` the engine falls back to the SYSTEM
// codepage, and every non-ASCII character in the help text arrives mangled — an em dash as `â€"`,
// a `·` as `Â·` — with nothing logged and nothing else wrong. It is invisible to every other
// test here, because the bytes in the file were always correct; only the reader was.
//
// This asserts the round trip: an em dash authored in the document has to come back out of the DOM as an
// em dash, and the classic mojibake prefix must not appear anywhere in the text.
@(test)
test_the_document_is_decoded_as_utf8 :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	testing.expect(
		t,
		strings.contains(compose_document(context.temp_allocator), `charset="utf-8"`),
		"the document must declare its encoding",
	)

	// Body text, through the parser and back.
	help := find(&app, "#help-generate-text")
	testing.expect(t, help != nil)
	text, err := sa.text(help, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, strings.contains(text, "—"), "an em dash must survive as an em dash")
	testing.expect(t, !strings.contains(text, "â"), "mojibake: UTF-8 read as a single-byte codepage")

	// And attribute values, which is what the hint bar reads.
	hint := hint_for(find(&app, "#seed"))
	testing.expect(t, strings.contains(hint, "—"), hint)
	testing.expect(t, !strings.contains(hint, "â"), hint)
}

// Every control a person can touch carries BOTH kinds of help: `title` for the engine's hover tooltip and
// `data-hint` for the hint bar. The two are separate mechanisms and it is easy to add a control with one,
// or with neither — which is how a UI ends up assuming its reader already knows the flags.
@(test)
test_every_control_is_documented :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// Interactive elements only: a label or a legend explains itself by being read.
	for selector in ([]string {
			"#count",
			"#format",
			"#seed",
			"#outdir",
			"#dd",
			"#fixed",
			"#all",
			"#generate",
			"#cancel",
			"#deal",
			"#sample",
			"#contract",
			"#target",
			"#analyse",
			"#clear",
			"#about",
			"#help-generate",
			"#help-analyse",
		}) {
		element := find(&app, selector)
		testing.expectf(t, element != nil, "no %s", selector)
		if element == nil {
			continue
		}
		title, _ := sa.attribute(element, "title", context.temp_allocator)
		hint, _ := sa.attribute(element, "data-hint", context.temp_allocator)
		testing.expectf(t, title != "", "%s has no title= (the engine's hover tooltip)", selector)
		testing.expectf(t, hint != "", "%s has no data-hint= (the hint bar)", selector)
		// A hint is a sentence, not a repeat of the label — the label is already on screen next to it.
		testing.expectf(t, len(hint) > 30, "%s's hint is too short to explain anything: %q", selector, hint)
	}
}

// The hint bar fills from whatever the pointer or the keyboard is on, and empties again. This is the whole
// mechanism: `data-hint` in the document, `.MOUSE`/`.FOCUS` in the subscription, one line of text out.
@(test)
test_the_hint_bar_follows_the_pointer :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	bar := find(&app, "#hint")
	testing.expect(t, bar != nil)

	// Straight through the same proc the events call, since a synthetic MOUSE_ENTER is the engine's to send.
	seed := find(&app, "#seed")
	hint := hint_for(seed)
	testing.expect(t, strings.contains(hint, "SAME deals"), hint)
	show_hint(&app, hint)
	shown, _ := sa.text(bar, context.temp_allocator)
	testing.expect_value(t, shown, hint)

	show_hint(&app, "")
	empty, _ := sa.text(bar, context.temp_allocator)
	testing.expect_value(t, empty, "")

	// A label or an inner span is what the pointer usually lands on, so the hint has to be found by
	// walking UP from the target. `#scenarios` carries one; its rendered rows do not.
	draw_scenarios(&app)
	pump(&app)
	rows, _ := sa.select_all(find(&app, "#scenarios"), ".row", context.temp_allocator)
	if len(rows) > 0 {
		if name, err := sa.select_first(rows[0], ".name"); err == nil {
			testing.expect(t, strings.contains(hint_for(name), "scenario"), hint_for(name))
		}
	}
}

// The `?` next to each panel legend toggles that panel's paragraph, and the panels start closed.
@(test)
test_the_panel_help_toggles :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	for pair in ([]struct {
			button, block: string,
		}{{"#help-generate", "#help-generate-text"}, {"#help-analyse", "#help-analyse-text"}}) {
		testing.expect_value(t, effective_display(&app, pair.block), "none") // closed to begin with

		sa.do_click(find(&app, pair.button))
		pump(&app)
		testing.expectf(t, effective_display(&app, pair.block) == "block", "%s did not open", pair.block)

		sa.do_click(find(&app, pair.button))
		pump(&app)
		testing.expectf(t, effective_display(&app, pair.block) == "none", "%s did not close again", pair.block)
	}
}

// Every control gives visible feedback under the pointer. Sciter's default stylesheet does NOT do this
// for you — measured: a bare `<button>` computes `background-color: transparent` at rest, hovered and
// active alike — so a stylesheet that sets a background and stops has produced a control that looks
// dead to the touch. `set_element_state` drives the same state bits a real pointer sets.
@(test)
test_controls_have_interaction_states :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// selector, and whether hover/active must differ from rest
	for probe in ([]struct {
			selector: string,
			active:   bool,
		} {
			{"#generate", true}, // the primary button
			{"#clear", true}, // the secondary (.ghost) button
			{"#about", true},
			{"#count", false}, // a text field: hover only
			{"#outdir", false},
		}) {
		element := find(&app, probe.selector)
		testing.expectf(t, element != nil, "no %s", probe.selector)
		if element == nil {
			continue
		}

		rest := background_in_state(&app, element, {})
		hover := background_in_state(&app, element, {.HOVER})
		testing.expectf(
			t,
			rest != hover,
			"%s does not react to the pointer: background stays %s on hover",
			probe.selector,
			rest,
		)
		if probe.active {
			pressed := background_in_state(&app, element, {.ACTIVE})
			testing.expectf(t, pressed != rest, "%s does not react to being pressed (%s)", probe.selector, rest)
		}
	}

	// A DISABLED button must NOT light up: `cancel` starts disabled, and its hover rule has to lose to the
	// disabled one. This is the half that ordinary eyeballing misses, because the button looks right until
	// you point at something you cannot click.
	cancel := find(&app, "#cancel")
	testing.expect(t, cancel != nil)
	set_enabled(&app, "#cancel", false)
	pump(&app)
	off_rest := background_in_state(&app, cancel, {})
	off_hover := background_in_state(&app, cancel, {.HOVER})
	testing.expect_value(t, off_hover, off_rest)
}

// An element's computed background in a given state, with the state left as it was found.
@(private = "file")
background_in_state :: proc(app: ^App, element: sa.Element, bits: sciter.Element_State_Bits) -> string {
	sa.set_element_state(element, bits, {}, true) // set the bits under test
	pump(app)
	value, _ := sa.style(element, "background-color", context.temp_allocator)
	sa.set_element_state(element, {}, bits, true) // and put them back
	pump(app)
	return value
}

// Clicking a row MOVES the selection. This is the test that was missing: the first version rendered the
// list correctly and asserted exactly that, while no click ever reached the host — a `<div>` has no
// behavior, so it raises no `.BUTTON_CLICK`, and the selection could never leave the first scenario.
// `do_click` goes through the same native controller a real click does, so `behavior: button` in the CSS
// is what both depend on.
@(test)
test_clicking_a_row_moves_the_selection :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	if len(bidding.registry) < 3 {
		return // needs somewhere to move to
	}

	// The same handler `main` installs, on the same window — so this exercises the real event path. It is
	// detached again because the windowless view outlives the test and `app` does not: the engine would be
	// left holding the address of a stack frame that has gone.
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	draw_scenarios(&app)
	// A native behavior attaches when the element's style is RESOLVED, not when it is inserted, so freshly
	// `set_html`'d rows have no controller until the engine has run a pass over them. A real window pumps
	// constantly and this is invisible there; a windowless view pumps only when told, so without this the
	// rows answer no click and the test blames the CSS.
	pump(&app)

	list := find(&app, "#scenarios")
	rows, err := sa.select_all(list, ".row", context.temp_allocator)
	testing.expect_value(t, err, nil)
	if len(rows) < 3 {
		return
	}

	// A row must answer the click at all — `handled = false` here IS the bug this test exists for.
	handled, cerr := sa.do_click(rows[2])
	testing.expect_value(t, cerr, nil)
	testing.expect(t, handled, "a row must carry a behavior that answers a click (behavior: button)")

	// `do_click` runs the behavior synchronously but the resulting BUTTON_CLICK is DELIVERED through the
	// event queue, so the handler has not run yet. Pump, then assert — the same shape
	// odin-sciter's examples/behavior.odin uses around its own click tests.
	pump(&app)
	testing.expect_value(t, app.selected, 2)

	// And the document followed the model: exactly one row marked, and it is that one.
	marked, merr := sa.select_all(find(&app, "#scenarios"), ".row.sel", context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, len(marked), 1)
	index, _ := sa.attribute(marked[0], "data-index", context.temp_allocator)
	testing.expect_value(t, index, "2")

	// And it moves again, rather than sticking wherever it first landed.
	fresh, _ := sa.select_all(find(&app, "#scenarios"), ".row", context.temp_allocator)
	sa.do_click(fresh[1])
	pump(&app)
	testing.expect_value(t, app.selected, 1)
}

// The scenario list is a projection of the registry, and the selection is part of it.
@(test)
test_the_scenario_list_renders_the_registry :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	draw_scenarios(&app)
	list := find(&app, "#scenarios")
	rows, err := sa.select_all(list, ".row", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, len(bidding.registry) > 0, "the bidding system must register scenarios")
	testing.expect_value(t, len(rows), len(bidding.registry))

	selected, serr := sa.select_all(list, ".row.sel", context.temp_allocator)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, len(selected), 1) // exactly the one `app.selected` names
}

// THE round-trip: the controls compose an argv, and norn's own parser accepts it and reads back what the
// controls said. Nothing here asserts on the argv's spelling — `cli.parse_args` is the authority, which
// is the whole reason the UI goes through it instead of building an `Options` by hand.
@(test)
test_the_generate_argv_is_valid_to_norns_parser :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#count", "24")
	type_into(&app, "#seed", "7")
	type_into(&app, "#outdir", "C:/tmp/deals")
	tick(&app, "#dd")
	tick(&app, "#fixed")

	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	app.job = job // so test_app_destroy frees it
	testing.expect_value(t, len(job.scenarios), 1) // the selected one, since #all is not ticked
	testing.expect_value(t, job.ext, ".html") // the default format is html-cards

	// What the worker does per scenario, minus the run itself.
	argv := make([dynamic]string, 0, len(job.argv) + 4, context.temp_allocator)
	append(&argv, ..job.argv)
	append(&argv, "-S", job.scenarios[0], "-o", "C:/tmp/deals/x.html")

	opts, ok, message := cli.parse_args(argv[:])
	testing.expectf(t, ok, "norn rejected the composed argv: %s", message)
	testing.expect_value(t, opts.count, 24)
	testing.expect_value(t, opts.format, norn.Output_Format.Html_Cards)
	testing.expect_value(t, opts.scenario, job.scenarios[0])
	testing.expect_value(t, opts.output, "C:/tmp/deals/x.html")
	testing.expect(t, opts.dd, "--dd must reach the parser")
	testing.expect(t, !opts.randomize_table, "--fixed-table must clear the randomised table")
	seed, has_seed := opts.seed.?
	testing.expect(t, has_seed)
	testing.expect_value(t, seed, u64(7))
	_, is_generate := opts.mode.(cli.Generate)
	testing.expect(t, is_generate)
}

// `every scenario` is what turns one job into the whole registry — the batch the `gen-all` recipe runs.
@(test)
test_every_scenario_queues_the_whole_registry :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#outdir", "C:/tmp/deals")
	tick(&app, "#all")

	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	app.job = job
	testing.expect_value(t, len(job.scenarios), len(bidding.registry))
}

// The other round-trip, through the advisor's parser. Note the deal arrives as ONE argument with its `-`
// hands intact: there is no shell here to split it, and `analyse.parse_args` reads the positional tail.
@(test)
test_the_analyse_argv_is_valid_to_the_analyse_parser :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#deal", `[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]`)
	type_into(&app, "#sample", "200")
	type_into(&app, "#contract", "3NT")
	type_into(&app, "#target", "9")

	job, err := analyse_job(&app)
	testing.expect_value(t, err, "")
	app.job = job

	args, perr := analyse.parse_args(job.argv, allow_stdin = false)
	defer analyse.args_free(&args)
	testing.expectf(t, perr == "", "the advisor rejected the composed argv: %s", perr)
	testing.expect_value(t, args.sample, 200)
	testing.expect_value(t, args.contract, "3NT")
	testing.expect_value(t, args.target, 9)

	// And the deal text still resolves to the two-hand board it named.
	boards, berr := analyse.resolve_boards(args.text)
	defer delete(boards)
	testing.expect_value(t, berr, "")
	testing.expect_value(t, len(boards), 1)
	testing.expect_value(t, boards[0].known, bit_set[norn.Seat]{.North, .South})
}

// The output directory is settled BEFORE anything is generated: made absolute, and created when missing.
// `norn:cli` writes the page only after generating it and does not create parents, so without this a typo
// costs a full run per scenario and then says `Not_Exist`.
@(test)
test_the_output_directory_is_absolute_and_created :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// A RELATIVE path with a component that does not exist yet: both behaviours in one.
	fresh := "target/debug/wb-outdir-probe/nested"
	if os.exists(fresh) {
		os.remove_all(fresh)
	}
	type_into(&app, "#outdir", fresh)

	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	app.job = job

	testing.expect(t, filepath.is_abs(job.out_dir), job.out_dir)
	testing.expect(t, os.is_dir(job.out_dir), "the directory must exist by the time a job holds it")
	slashed := strings.replace_all(job.out_dir, "\\", "/", context.temp_allocator) or_else job.out_dir
	testing.expect(t, strings.contains(slashed, "wb-outdir-probe/nested"), job.out_dir)

	// A path that names an existing FILE is a refusal, not a directory to create.
	type_into(&app, "#outdir", PARITY_FILE)
	_, ferr := generate_job(&app)
	testing.expect(t, strings.contains(ferr, "is a file"), ferr)
}

// The refusals that would otherwise reach a parser as something confusing (an empty `-o`, an empty
// positional) and fail deeper in, with a worse message.
@(test)
test_the_jobs_refuse_incomplete_input :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#outdir", "")
	_, gerr := generate_job(&app)
	testing.expect(t, strings.contains(gerr, "output dir"), gerr)

	type_into(&app, "#outdir", "C:/tmp/deals")
	type_into(&app, "#count", "nonsense")
	_, cerr := generate_job(&app)
	testing.expect(t, strings.contains(cerr, "deals"), cerr)

	type_into(&app, "#deal", "   ")
	_, aerr := analyse_job(&app)
	testing.expect(t, strings.contains(aerr, "paste a deal"), aerr)
}

// The transcript reaches the report pane through the `plaintext` behavior's `content` property (or the
// `set_text` fallback), which is the one piece of the UI whose write path is not an ordinary DOM call.
@(test)
test_the_transcript_reaches_the_report_pane :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	strings.write_string(&app.transcript, "hello from the host\n")
	draw_transcript(&app)

	content, ok := report_content(&app, context.temp_allocator)
	testing.expect(t, ok, "the report pane must publish a plaintext asset to read back")
	testing.expect(t, strings.contains(content, "hello from the host"), content)

	// The trailing-newline trim, pinned: without it the widget reports a leading blank line, and the pane
	// shows one. (Measured — see draw_transcript's note.)
	testing.expect(t, !strings.has_prefix(content, "\n") && !strings.has_prefix(content, "\r\n"), content)

	// `sciter_app.text` reads the element's own text, which for this behavior is empty however much
	// content it holds. Pinned so nobody "simplifies" report_content into a text() call.
	report := find(&app, "#report")
	own_text, terr := sa.text(report, context.temp_allocator)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, own_text, "")
}

// The generate path, actually run: the worker's per-scenario body (parse args, wire hooks, `cli.run`)
// against a real scenario, writing a real card page. Seeded and `--fixed-table`, so the bytes are
// reproducible — which is what lets `just sims wb-cli-parity` diff this file against the same run through
// `sim.exe` and prove the window and the command line produce the same page.
//
// Deliberately NOT --dd: that would pull DDS into a test binary that also runs the windowless engine, and
// the hook wiring is one assignment either way (its table is `sim_hooks`', tested by being shared).
@(test)
test_the_generate_path_writes_the_same_page_the_cli_does :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#count", "4")
	type_into(&app, "#seed", "42")
	type_into(&app, "#outdir", PARITY_DIR)
	tick(&app, "#fixed")

	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	app.job = job
	if len(job.scenarios) != 1 {
		return
	}

	// Exactly what `work_generate` does for one scenario, minus the `post_callback`s.
	argv := make([dynamic]string, 0, len(job.argv) + 4, context.temp_allocator)
	append(&argv, ..job.argv)
	append(&argv, "-S", job.scenarios[0], "-o", PARITY_FILE)

	opts, ok, message := cli.parse_args(argv[:])
	testing.expectf(t, ok, "norn rejected the composed argv: %s", message)
	run_ok, run_message := cli.run(bidding.registry, opts)
	testing.expectf(t, run_ok, "the in-process run failed: %s", run_message)

	page, rerr := os.read_entire_file_from_path(PARITY_FILE, context.temp_allocator)
	testing.expectf(t, rerr == nil, "no page at %s: %v", PARITY_FILE, rerr)
	testing.expect(t, len(page) > 1000, "a card page is more than a few bytes")
	testing.expect(t, strings.has_prefix(string(page), "<!DOCTYPE html>"), "and it is a document")
	testing.expect(t, strings.contains(string(page), "compass"), "carrying the card page's own markup")
	// Titled by the scenario that ran — asked of the registry rather than spelled out, so adding or
	// reordering scenarios cannot break this.
	testing.expect(
		t,
		strings.contains(string(page), cli.scenario_title(app.scenarios[app.selected])),
		"the page must be titled by the scenario that ran",
	)
}

// Where the parity test writes. A fixed path rather than a temp one, because the point is for a recipe to
// pick the file up afterwards and diff it.
PARITY_DIR :: "target/debug"
PARITY_FILE :: "target/debug/wb-parity.html"

@(test)
test_extension_follows_the_format :: proc(t: ^testing.T) {
	testing.expect_value(t, extension_for("html-cards"), ".html")
	testing.expect_value(t, extension_for("html-handviewer"), ".html")
	testing.expect_value(t, extension_for("pbn"), ".pbn")
	testing.expect_value(t, extension_for("pretty"), ".txt")
	testing.expect_value(t, extension_for("line"), ".txt")
}
