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
import "core:hash"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
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
import bml "markup:."
import "norn:cli"
import "norn:combo"
import "norn:norn"
import "outline"
import "perf"
import "prefs"
import "preview"
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
PAGE :: uintptr(5) // a card page is ready in `App.page`; show it in the frame
DEAL :: uintptr(6) // OCR read a deal out of a dropped image; it is in `App.deal`, put it in the box
LIVE :: uintptr(7) // the live preview`s debounce ran out; render the buffer (see `on_frame_event`)

Job_Kind :: enum {
	Generate,
	Analyse,
	Ocr, // a dropped hand-diagram image: read it, then analyse what was read
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
	echo:      bool, // generate only: small text output goes into the report pane as well as to the file
	want_page: bool, // analyse and ocr: the card page into the frame, instead of the text report
	image:     string, // ocr only: the dropped image, an absolute path
}

App :: struct {
	using host:    sa.Host_Handler,
	window:        sa.Window,
	handler:       sa.Event_Handler,
	// The drop handler is a SECOND handler, on the document root rather than on the window: measured, the
	// EXCHANGE group does not reach a window handler at all (the drop was refused in silence, which looks
	// exactly like the window not accepting drops). On the root it covers every element in the document,
	// so the whole window is the drop target.
	drops:         sa.Event_Handler,

	// The catalogue, straight from the bidding system. `selected` indexes it.
	scenarios:     []cli.Scenario,
	selected:      int,

	// Shared with the worker. `post_callback` says THAT something changed; the lock is what makes it safe
	// to read WHAT.
	mutex:         sync.Mutex,
	transcript:    strings.Builder,
	failure:       string,

	// The card page, rendered by the worker and shown by the engine thread (PAGE). A whole document
	// rather than a line, so it travels here like `failure` does.
	page:          string,

	// The deal OCR read out of a dropped image, travelling to the engine thread (DEAL) so the analyse
	// box shows what was actually read — the OCR is a guess at a picture, and an unreadable digit is a
	// thing to see and correct rather than to have silently analysed.
	deal:          string,

	// The one flag that travels the other way (engine thread -> worker). Atomic because the worker reads
	// it between scenarios and the UI writes it at most once per job.
	cancel:        bool,

	// The BML editor, all engine-thread state. `docs` is where the `.bml` corpus was found (empty if it
	// was not), `bml_names` the files in it, and `bml_open` the one in the editor — a name rather than an
	// index, so a re-listed directory cannot silently change which file `save` writes to.
	// The view About was entered from, so closing it goes back there rather than to the panes.
	before_about:  View,

	// Is there a hand page to show? The deals bar`s `hand page` and `wide` are disabled until there is, and `do_click`
	// does NOT honour a disabled button (measured — the behavior runs and the click is delivered), so the
	// tab handler asks this rather than trusting the attribute. Rule 1: the model is the truth and the
	// `disabled` attribute is the projection of it.
	page_ready:    bool,

	// Is there a rendered preview in the frame? Once there is, it FOLLOWS the buffer — opening another file
	// re-renders it, because a preview of the file you were looking at a moment ago is worse than no
	// preview: it looks like the file you just clicked.
	previewed:     bool,
	docs:          string,
	bml_names:     []string,
	bml_open:      string,
	bml_crlf:      bool, // the line endings the file arrived with, so saving does not rewrite all of them
	bml_armed:     bool, // a switch away from unsaved text was refused once; the next one goes through
	// Check `[label](#Anchor)` as well? Off by default, and the button says so: a CHAPTER of this corpus
	// links to headings in its sibling files on purpose, so on one chapter the check is mostly noise. On
	// `bidding-system.bml`, which includes them all, every warning it raises is a real broken link.
	bml_links:     bool,
	// How much of the notes the preview shows, and whether the pane is up at all. `bml_scope` is per FILE
	// (see `scope_for_file`): remembered if it was chosen, otherwise decided by the document's size.
	bml_scope:     Preview_Scope,
	// Has the scope been settled for the file that is open? The size-based default is applied ONCE per file;
	// after that the state is whatever it is, or a press of `section`/`whole` would be undone by the very
	// re-render it asks for.
	bml_scope_set: bool,
	bml_showing:   bool, // is the preview pane up? `preview` closes it, and closing it frees the document
	// THE PREVIEW IS LIVE: once the pane is up it follows the buffer, on a debounce, without being asked.
	// `bml_live_base` is the idle a keystroke has to survive before a render (0 turns the whole thing off),
	// `bml_preview_cost` is how long the LAST render took - which is what the debounce is scaled by, so a
	// document that is expensive to render is also one that is left alone for longer. `bml_rendering` is the
	// re-entrancy guard: a render pumps the engine, so a second one must not start inside the first.
	// `bml_rendered` fingerprints the text the pane is showing, so a timer that fires over an unchanged
	// buffer (an arrow key, a modifier, an edit that was undone) costs nothing.
	bml_live_base:    time.Duration,
	bml_preview_cost: time.Duration,
	bml_rendering:    bool,
	bml_rendered:     u64,

	// The heading palette (CTRL+R). `goto_all` is the whole corpus's headings, OWNED (see `build_goto_index`
	// - the files' text is read, the headings cloned out of it and the text dropped); `goto_rows` is what the
	// list on screen is showing, in list order, so a click or ENTER can name a destination by row rather
	// than by re-running the ranking and hoping it comes out the same. `goto_sel` is the highlighted row.
	goto_open:     bool,
	goto_sel:      int,
	goto_all:      []outline.Heading,
	goto_rows:     []outline.Heading,
	// The preview scroll that has not landed yet, and how many times it has been tried. A frame's
	// sub-document is laid out on the engine's schedule, so the scroll is RETRIED on a timer until the
	// numbers say it moved - see `scroll_preview_to_heading`.
	scroll_want:   string,
	scroll_tries:  int,
	frame_handler: sa.Event_Handler,
	prefs:         prefs.Prefs,
	prefs_path:    string,

	// Engine-thread only, so no lock.
	job:           Job,
	worker:        ^thread.Thread,
	running:       bool,
	allocator:     runtime.Allocator,
}

// Which of the three mutually exclusive top-level views is on screen. They REPLACE each other rather than
// stack, because an overlay wants an out-of-flow percentage height and this engine lays that out 1px tall
// (see the CSS header). One enum rather than three independent toggles: with independent ones, opening
// About over the hand pane showed both.
View :: enum {
	Panes, // the scenario list, the command panels, and the hand page beside them: the default
	About,
	Editor, // the BML editor, source and preview side by side
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
	case .Ocr:
		work_ocr(app)
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

		// NOT temp memory, and this is the one non-obvious rule of this loop: a library on the far side of
		// `cli.run` RESETS this thread's temp allocator. `combo.annotate`'s Html_Cards path ends with
		// `free_all(context.temp_allocator)` (deliberately — it recycles a per-deal arena), and `cli`
		// holds our `-o` path as a plain string for the length of the run. A temp-allocated path therefore
		// survives the first scenarios and then comes back as recycled bytes: measured as
		// `could not write to "\x00\x00\x00…": Not_Exist` on the 46th scenario of an
		// "every scenario, --dd, html-cards" batch, having written the previous 45 correctly.
		command := scenario_command(&app.job, name)
		defer command_free(&command)

		opts, ok, message := cli.parse_args(command.argv[:])
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
		transcribe(app, fmt.tprintf("[%d/%d] %s -> %s", i + 1, total, name, command.path))
		if app.job.echo {
			echo_output(app, command.path)
		}
		sa.post_callback(app.window, PROGRESS, uintptr((i + 1) * 100 / max(total, 1)))
	}
	sa.post_callback(app.window, FINISHED, 0)
}

// One scenario's command line: the job's shared flags plus its own `-S <name> -o <path>`, and the path
// itself. On the HEAP (freed by `command_free`), never on `context.temp_allocator` — see the note in
// `work_generate`, which is where the cost of getting this wrong is written down.
Scenario_Command :: struct {
	argv: [dynamic]string,
	path: string,
}

scenario_command :: proc(job: ^Job, name: string, allocator := context.allocator) -> (command: Scenario_Command) {
	file := fmt.aprintf("%s%s", name, job.ext, allocator = allocator)
	defer delete(file, allocator)
	command.path, _ = filepath.join({job.out_dir, file}, allocator)

	command.argv = make([dynamic]string, 0, len(job.argv) + 4, allocator)
	append(&command.argv, ..job.argv)
	append(&command.argv, "-S", name, "-o", command.path)
	return
}

// Frees only what `scenario_command` allocated: the argv SLOTS are borrowed (the job's strings, the
// scenario's name, two literals and `path`), so the elements are not freed here.
command_free :: proc(command: ^Scenario_Command, allocator := context.allocator) {
	delete(command.argv)
	delete(command.path, allocator)
	command^ = {}
}

work_analyse :: proc(app: ^App) {
	run_analysis(app, app.job.argv)
}

// The analysis itself, shared by the analyse button and the dropped image: the argv differs (the OCR path
// appends the deal it just read), everything after it does not. Terminal on every path, like the workers
// it is called from.
run_analysis :: proc(app: ^App, argv: []string) {
	args, err := analyse.parse_args(argv, allow_stdin = false)
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

	// "as card page": the same run, with the page asked for as TEXT rather than as a file
	// (`analyse.builder_page_sink`), so nothing is written to disk and no temp file is involved. The
	// diagnostics still land in the transcript; the document goes to the frame.
	page_b: strings.Builder
	sink := analyse.builder_sink(&b)
	if app.job.want_page {
		page_b = strings.builder_make()
		sink = analyse.builder_page_sink(&b, &page_b)
	}
	defer if app.job.want_page {
		strings.builder_destroy(&page_b)
	}

	result := analyse.run(sink, &args)

	transcribe(app, strings.to_string(b))
	if result != .Ok {
		fail(app, fmt.tprintf("analysis ended with %v", result))
		return
	}
	if app.job.want_page {
		sync.lock(&app.mutex)
		delete(app.page)
		app.page = strings.clone(strings.to_string(page_b))
		sync.unlock(&app.mutex)
		sa.post_callback(app.window, PAGE)
	}
	sa.post_callback(app.window, PROGRESS, 100)
	sa.post_callback(app.window, FINISHED, 0)
}

// A hand-diagram image someone dropped on the window: OCR it to a deal, show what was read, then analyse
// it exactly as the analyse button would. Worker-side, and terminal on every path.
//
// This is the ONE subprocess in the workbench, and it is a deliberate exception rather than a slip: the
// reader is `hand-ocr`, a SEPARATE python project (a vision stack — opencv, numpy, pillow), so there is
// nothing to link in-process. It is spawned the same way `tools/ocr_analyse.py` does — `uv run --project
// <dir>`, hand-ocr's own project environment rather than the script's isolated PEP-723 one, which has no
// opencv — and the PBN it prints on stdout is fed straight to `analyse.run` in this process. No temp file
// either way.
work_ocr :: proc(app: ^App) {
	dir := hand_ocr_dir(context.temp_allocator)
	if !os.is_dir(dir) {
		// Named rather than "OCR failed": the fix is a checkout or an environment variable, and neither is
		// guessable from a spawn error.
		fail(app, fmt.tprintf("hand-ocr is not at %s — clone it there, or set HAND_OCR_DIR", dir))
		return
	}

	command := ocr_command(app.job.image, dir, context.temp_allocator)
	transcribe(app, fmt.tprintf("reading %s with hand-ocr…", app.job.image))

	state, stdout, stderr, exec_err := os.process_exec({command = command}, context.temp_allocator)
	if exec_err != nil {
		// `uv` missing is the common shape of this, and it is worth saying so: the alternative message is
		// an errno nobody can act on.
		fail(app, fmt.tprintf("could not run uv (%v) — is uv installed and on PATH?", exec_err))
		return
	}
	if len(stderr) > 0 {
		// hand-ocr writes its diagnostics here; they explain a poor read, so they belong in the transcript
		// whether or not the run succeeded.
		transcribe(app, strings.trim_space(string(stderr)))
	}
	if !state.success {
		fail(app, fmt.tprintf("hand-ocr exited with %d — see the transcript", state.exit_code))
		return
	}

	deal := strings.trim_space(string(stdout))
	if !strings.contains(deal, "[Deal") {
		fail(app, fmt.tprintf("hand-ocr did not produce a deal: %q", deal))
		return
	}

	// Into the box BEFORE the analysis: OCR is a guess at a picture. Seeing the deal it read is what lets a
	// misread card be corrected and re-analysed by hand, and it is also the only record of what was analysed
	// once the page is on screen.
	sync.lock(&app.mutex)
	delete(app.deal)
	app.deal = strings.clone(deal)
	sync.unlock(&app.mutex)
	sa.post_callback(app.window, DEAL)
	transcribe(app, deal)

	// The deal goes last, as one argument — the parser's positional overflow, same as the analyse button.
	argv := make([dynamic]string, 0, len(app.job.argv) + 1, context.temp_allocator)
	append(&argv, ..app.job.argv)
	append(&argv, deal)
	run_analysis(app, argv[:])
}

// Where the hand-ocr checkout is. The same variable the justfile exports (`HAND_OCR_DIR`), so the desktop
// app and the `ocr-analyse` recipe are pointed at one place, with the same `~/dev/<repo>` default the norn
// and dds collections use.
hand_ocr_dir :: proc(allocator := context.allocator) -> string {
	if dir := os.get_env("HAND_OCR_DIR", allocator); dir != "" {
		return dir
	}
	home := os.get_env("USERPROFILE", context.temp_allocator)
	if home == "" {
		home = os.get_env("HOME", context.temp_allocator)
	}
	joined, _ := filepath.join({home, "dev", "bridge-hand-ocr"}, allocator)
	return joined
}

// The hand-ocr command line, as an argv (there is no shell, so a space in the image path needs no quoting).
// Split out because it is the part worth pinning in a test: `--project <dir>` is what picks hand-ocr's own
// environment, and `--format pbn` is what `analyse.parse_args` can then read.
ocr_command :: proc(image: string, dir: string, allocator := context.allocator) -> []string {
	script, _ := filepath.join({dir, "hand-ocr.py"}, allocator)
	out := make([]string, 9, allocator)
	out[0] = "uv"
	out[1] = "run"
	out[2] = "--project"
	out[3] = dir
	out[4] = "python"
	out[5] = script
	out[6] = image
	out[7] = "--format"
	out[8] = "pbn"
	return out
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

	case DEAL:
		sync.lock(&app.mutex)
		deal := strings.clone(app.deal, context.temp_allocator)
		delete(app.deal)
		app.deal = ""
		sync.unlock(&app.mutex)

		set_input(app, "#deal", deal)

	case PAGE:
		sync.lock(&app.mutex)
		page := strings.clone(app.page, context.temp_allocator)
		delete(app.page)
		app.page = ""
		sync.unlock(&app.mutex)

		if !show_page_html(app, page, "analysed deal") {
			set_status(app, "the hand page could not be loaded into the pane")
		}

	case FINISHED:
		set_status(app, "cancelled" if posted.lparam == 1 else "done")
		draw_transcript(app)
		job_ended(app)

	case LIVE:
		// The only message that does not come from a worker thread. It comes from the frame`s TIMER handler,
		// one dispatch earlier, and this is why: the render REPLACES the document inside that same frame, and
		// doing it from the frame`s own handler tears down the element tree the engine is currently
		// dispatching into - the window stops answering. Posted, it happens on the next turn of the pump with
		// no handler on the stack.
		live_preview_tick(app)
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

	// "view page" resolves from the SELECTION rather than from what this run happened to write, so there
	// is no state to update here — a batch that just wrote 110 pages leaves the selected scenario's page
	// exactly where the button looks for it.
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
	delete(job.image, allocator)
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
	n, count_ok := strconv.parse_int(strings.trim_space(count))
	if !count_ok || n <= 0 {
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
			kind      = .Generate,
			argv      = clone_strings(argv[:], app.allocator),
			scenarios = clone_strings(names[:], app.allocator),
			out_dir   = strings.clone(out_dir, app.allocator),
			ext       = extension_for(format),
			// For the echo below: a small text run is worth showing in the pane, a 48-scenario batch of html
			// is not.
			echo      = text_format(format) && n <= ECHO_MAX_DEALS,
		}, ""
}

analyse_job :: proc(app: ^App) -> (job: Job, err: string) {
	deal := strings.trim_space(read_text(app, "#deal"))
	if deal == "" {
		return {}, "paste a deal: a PBN tag, a bare N:..., a LIN record or a hand URL"
	}

	argv, flag_err := analyse_flags(app)
	if flag_err != "" {
		return {}, flag_err
	}
	// The deal goes last, as one argument: the parser's positional overflow. Quoting is not a concern
	// here (there is no shell), so the `-` hands of a two-hand deal arrive intact inside this one string.
	append(&argv, deal)

	// No `--html`: the page is asked for in memory (see `analyse.builder_page_sink`) and goes to the
	// frame. Nothing here writes a file, so there is no path to compose and nothing to clean up.
	return Job{kind = .Analyse, argv = clone_strings(argv[:], app.allocator), want_page = read_bool(app, "#as-page")},
		""
}

// The analyse panel's flags, WITHOUT a deal — everything the two ways in have in common. The analyse
// button appends the pasted deal; the OCR path cannot, because the deal does not exist until hand-ocr has
// read the picture, so it appends its own on the worker thread. Temp memory (the caller clones).
analyse_flags :: proc(app: ^App) -> (argv: [dynamic]string, err: string) {
	argv = make([dynamic]string, 0, 8, context.temp_allocator)
	if sample := strings.trim_space(read_text(app, "#sample")); sample != "" && sample != "0" {
		if n, ok := strconv.parse_int(sample); !ok || n < 0 {
			return nil, fmt.tprintf("sample: %q is not a number", sample)
		}
		append(&argv, "--sample", sample)
	}
	if contract := strings.trim_space(read_text(app, "#contract")); contract != "" {
		append(&argv, "--contract", contract)
	}
	if target := strings.trim_space(read_text(app, "#target")); target != "" && target != "0" {
		append(&argv, "--target", target)
	}
	return argv, ""
}

// A dropped hand-diagram image: the analyse panel's flags, plus the picture to read them against. The
// panel's controls apply unchanged — a drop is the analyse button with the deal arriving from a picture
// instead of the clipboard, so `sample`, `contract`, `target` and `as card page` all still mean what they
// say on screen.
ocr_job :: proc(app: ^App, image: string) -> (job: Job, err: string) {
	argv, flag_err := analyse_flags(app)
	if flag_err != "" {
		return {}, flag_err
	}
	return Job {
			kind = .Ocr,
			argv = clone_strings(argv[:], app.allocator),
			want_page = read_bool(app, "#as-page"),
			image = strings.clone(image, app.allocator),
		},
		""
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

// What "view" means for a format, because it is three different things.
//
// `.Cards` is the interactive page the workbench hosts itself. `.Handviewer` is a page of `<iframe>`s onto
// bridgebase.com — a whole website, per deal, needing a browser's JS: in the frame it loads slowly and then
// says "javascript is disabled in the web browser", which is the site being right about us. `.Text` is
// pretty/line/pbn, which is text and can simply be shown as text.
Output_Kind :: enum {
	Cards,
	Handviewer,
	Text,
}

// What the SELECTED scenario has on disk, and what kind of thing it is. The NEWEST of the outputs it could
// have, deliberately — not the one the format dropdown currently names.
//
// The dropdown says what the next RUN will write; it is not a statement about what exists. Following it made
// the button lie in both directions: switch to `pbn` after generating pages and it reported nothing to view,
// switch to `html-cards` after a text run and it offered a page that was not there. So this asks the
// filesystem instead, and the format dropdown is left to mean what it says.
//
// Note what this does NOT do: create the directory. `resolve_out_dir` does, because generating into a
// missing directory is a wasted run; LOOKING for one must not leave a folder behind.
selected_output :: proc(app: ^App) -> (path: string, kind: Output_Kind, ok: bool, why: string) {
	if app.selected < 0 || app.selected >= len(app.scenarios) {
		return "", .Text, false, "pick a scenario in the list first"
	}
	name := app.scenarios[app.selected].name

	typed := strings.trim_space(read_text(app, "#outdir"))
	if typed == "" {
		return "", .Text, false, "set an output directory to look in"
	}
	dir, abs_err := filepath.abs(typed, context.temp_allocator)
	if abs_err != nil {
		return "", .Text, false, fmt.tprintf("output dir: %q is not a usable path", typed)
	}

	// Every extension a format can write. `.html` covers BOTH html formats, which is why the kind of an
	// html file is decided by looking inside it rather than at its name.
	newest_time: time.Time
	for extension in ([]string{".html", ".txt", ".pbn", ".lin", ".hv.txt", ".line", ".num"}) {
		candidate, _ := filepath.join({dir, fmt.tprintf("%s%s", name, extension)}, context.temp_allocator)
		info, stat_err := os.stat(candidate, context.temp_allocator)
		if stat_err != nil {
			continue
		}
		if path == "" || time.diff(newest_time, info.modification_time) > 0 {
			path, newest_time = candidate, info.modification_time
		}
	}
	if path == "" {
		return "", .Text, false, fmt.tprintf(
			"nothing generated for %s yet — press generate (looked in %s)",
			name,
			dir,
		)
	}
	return path, file_kind(path), true, ""
}

// Which kind of output a file is. The extension answers it for text; for `.html` the two formats share one,
// so the file itself is asked — a handviewer page is a page of `<iframe>`s onto bridgebase.com and says so in
// its first few KB, and a cards page carries the carousel's own `nc-track`.
file_kind :: proc(path: string) -> Output_Kind {
	if !strings.has_suffix(path, ".html") {
		return .Text
	}
	// The head of the file is enough for both markers, and a 48-deal page is a quarter of a megabyte.
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return .Cards // unreadable: let the frame report it rather than guessing a browser hand-off
	}
	head := string(data)
	if len(head) > 16 * 1024 {
		head = head[:16 * 1024]
	}
	if strings.contains(head, "nc-track") {
		return .Cards
	}
	if strings.contains(head, "handviewer") || strings.contains(head, "<iframe") {
		return .Handviewer
	}
	return .Cards
}

// Say what picking a scenario means for the "view page" button, in the status line: the page it would open,
// or that there is none yet. Cheap, and it answers the question before the click rather than after.
note_selected_page :: proc(app: ^App) {
	if app.running {
		return // the status line belongs to the run while one is going
	}
	path, _, ok, why := selected_output(app)
	if ok {
		set_status(app, fmt.tprintf("output: %s", path))
		return
	}
	set_status(app, why)
}

/*
The file extension a format implies, for the per-scenario output path.

ONE EXTENSION PER FORMAT, and the reason is not tidiness: every text format used to write `<scenario>.txt`,
so generating a scenario as `pretty` and then as `line` OVERWROTE the first, and "view page" could not tell
which of the two it was about to open. Now the name says what is in it:

	pbn          .pbn      the file interchange format, and the one other tools read
	lin          .lin      BBO's record format - the one a bridgebase / IntoBridge hand LINK carries
	handviewer   .hv.txt   bridgebase handviewer QUERY STRINGS - see below, this is not `.lin`
	line         .line     deal.exe's one-line-per-deal format
	numeric      .num      the four hands as numbers
	pretty       .txt      the human-readable one, and the default for anything new

NOT `.lin`, and the distinction cost a wrong name once. `-f handviewer` emits bridgebase handviewer
QUERY PARAMETERS, one deal a line:

	n=sAThJ8dJ9cAJT7542&s=s632hA9754d43cK83&e=sQ9875hK32dA865c6&w=sKJ4hQT6dKQT72cQ9&a=_&v=n&d=n

which is what `-f html-handviewer` appends to `https://www.bridgebase.com/tools/handviewer.html?` in its
iframes. A `.lin` is a different thing entirely - BBO's own record format (`pn|…|md|…|mb|…|pc|…`), which is
what a bridgebase or IntoBridge hand LINK carries and what `norn/lin.odin` READS for the advisor. Nothing
here writes one, so nothing here should claim the extension.

The two html formats deliberately SHARE `.html`, because a page's kind is read from INSIDE it (`file_kind`
looks for `nc-track` or `handviewer`) - that was already true and is what lets a page generated last month
still open correctly.
*/
extension_for :: proc(format: string) -> string {
	switch format {
	case "html-cards", "html-handviewer":
		return ".html"
	case "pbn":
		return ".pbn"
	case "lin":
		return ".lin"
	case "handviewer":
		// `.hv.txt`: text, and the OS still treats it as text, but it cannot collide with `pretty`.
		return ".hv.txt"
	case "line":
		return ".line"
	case "numeric":
		return ".num"
	}
	return ".txt"
}

// Is this a format whose output is text a person can read in the pane, rather than a page for the frame?
text_format :: proc(format: string) -> bool {
	switch format {
	case "html-cards", "html-handviewer":
		return false
	}
	return true
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
//
// About is the one place with a `close`, and it earns it: it is a modal errand rather than a place, entered
// from anywhere. Closing it goes back to WHERE YOU WERE — which is what the tab strip still says, since
// `show_view` leaves the marking alone for About — and not to the panes, which would throw away the chapter
// or a half-typed chapter's worth of context for no reason.
show_about :: proc(app: ^App, shown: bool) {
	if shown {
		app.before_about = current_view(app)
		show_view(app, .About)
		return
	}
	show_view(app, app.before_about)
}

// The one place a view is chosen. Every other caller names a `View`, so no combination of buttons can
// leave two of them on screen at once.
//
// It also marks the TABS, which is why nothing else has to: the header is a projection of this enum, so a
// view reached from a button (a page that has just been generated, say) lights up its tab without the
// button knowing tabs exist. About is not a tab and leaves the marking alone — it is entered from anywhere
// and left by going back to where you were, so the strip should still say where that is.
show_view :: proc(app: ^App, view: View) {
	// The heading palette belongs to the notes view, and its keys are claimed while it is open — so leaving
	// the view closes it rather than leaving ESCAPE and the arrows captured behind another tab.
	if view != .Editor {
		close_goto(app, refocus = false)
	}
	set_shown(app, ".panes", view == .Panes)
	set_shown(app, "#about-panel", view == .About)
	set_shown(app, "#editview", view == .Editor)
	if view != .About {
		mark_tab(app, view)
	}
}

// Put the accent under the tab for `view`. Read-and-set rather than remembered, like everything else here:
// the document holds the projection and `current_view` can always be asked what is on screen.
mark_tab :: proc(app: ^App, view: View) {
	for tab in ([]struct {
			selector: string,
			view:     View,
		} {
			{`.tab[data-view="panes"]`, .Panes},
			{`.tab[data-view="editor"]`, .Editor},
		}) {
		element := find(app, tab.selector)
		if element == nil {
			continue
		}
		// `set_attribute` with "" REMOVES it, which is what deselecting is — the same shape `set_enabled`
		// uses for `disabled`.
		sa.set_attribute(element, "class", "tab sel" if tab.view == view else "tab")
	}
}

// There is now a hand page to show (or there is not). The bar`s two buttons are dead until there is
// something behind them, and stay live afterwards: closing the pane and opening it again must not need the
// page regenerating.
page_ready :: proc(app: ^App, ready: bool) {
	app.page_ready = ready
	set_enabled(app, "#deal-page", ready)
	set_enabled(app, "#deal-wide", ready)
}

/*
THE HAND PANE, and the two other things the deals bar folds.

The hand page was a third TAB once, and a tab was the wrong shape for it: the controls that make a set of
deals and the deals themselves are one activity, and going to look at the result meant leaving the controls
behind. It is a PANE of the deals view now - the same arrangement the notes view has always had, and the
same two classes (`.bar`, `.split`) so there is one splitter idiom in the window rather than two.

Three toggles, none of them a mode: the scenario list folds away, the pane opens and closes, and `wide` gives
the pane everything except the list. All three are READ FROM THE DOCUMENT rather than remembered in a flag,
the way `current_view` is - the display IS the state, and a second copy of it is a second thing to get
wrong. They are remembered across sessions in the host prefs, because a layout is a property of how someone
works rather than of a run.

CLOSING THE PANE IS ALSO HOW ITS MEMORY COMES BACK: a 48-deal page is ~86MB of laid-out document (measured),
and `display: none` is what makes layout cheap here - `visibility` keeps every box.
*/
page_pane_shown :: proc(app: ^App) -> bool {
	return !effective_display_is_hidden(app, "#pageview")
}

pane_is_wide :: proc(app: ^App) -> bool {
	return effective_display_is_hidden(app, ".work")
}

scenario_list_shown :: proc(app: ^App) -> bool {
	return !effective_display_is_hidden(app, "#scenario-list")
}

// Open or close the pane. Opening brings the deals view forward, because the pane belongs to it and a page
// that arrived while the notes were up should not silently change what the notes view is showing; and it
// gives the framed page the keyboard, so its own arrows and seat keys work at once.
//
// CLOSING A WIDE PANE UNWIDENS IT. Otherwise the work stays hidden with nothing beside it - a deals view
// showing a scenario list and an empty column, with no button on screen saying how to get the controls back.
show_page_pane :: proc(app: ^App, shown: bool) {
	if shown && current_view(app) != .Panes {
		show_view(app, .Panes)
	}
	set_shown(app, "#pageview", shown)
	if !shown {
		set_shown(app, ".work", true)
	}
	draw_deal_bar(app)
	if shown {
		focus_page(app)
	}
	remember_deals_layout(app)
}

// `wide` hides the WORK rather than growing the pane: both panes are `width: *`, so the pane takes what the
// work stops asking for. It implies the pane is open - widening a closed pane would leave the view empty.
set_pane_wide :: proc(app: ^App, wide: bool) {
	if wide && !page_pane_shown(app) {
		show_page_pane(app, true)
	}
	set_shown(app, ".work", !wide)
	draw_deal_bar(app)
	remember_deals_layout(app)
}

show_scenario_list :: proc(app: ^App, shown: bool) {
	set_shown(app, "#scenario-list", shown)
	draw_deal_bar(app)
	remember_deals_layout(app)
}

// The bar says what the next press does, the way the notes bar`s `preview`/`close` does - a label that
// names the state instead would leave "what happens if I press it" to be guessed.
draw_deal_bar :: proc(app: ^App) {
	set_text_at(app, "#deal-page", page_pane_shown(app) ? "close page" : "hand page")
	set_text_at(app, "#deal-wide", pane_is_wide(app) ? "with controls" : "wide")
}

// The layout, remembered across sessions. Three booleans in the host prefs file beside the zoom - the same
// place and for the same reason: they belong to the person rather than to the document.
DEALS_PANE_PREF :: "deals.pane"
DEALS_WIDE_PREF :: "deals.wide"
DEALS_LIST_PREF :: "deals.list"

remember_deals_layout :: proc(app: ^App) {
	if app.prefs_path == "" {
		return // no prefs file yet (a test app); the layout is still whatever the document says
	}
	prefs.set(&app.prefs, DEALS_PANE_PREF, page_pane_shown(app) ? "open" : "closed")
	prefs.set(&app.prefs, DEALS_WIDE_PREF, pane_is_wide(app) ? "wide" : "with-controls")
	prefs.set(&app.prefs, DEALS_LIST_PREF, scenario_list_shown(app) ? "open" : "closed")
	_ = prefs.save(&app.prefs, app.prefs_path)
}

// And restored at startup. The PANE is not restored open: there is nothing in it until something has been
// generated or analysed, and an empty pane beside the controls would be a promise the window cannot keep.
restore_deals_layout :: proc(app: ^App) {
	if remembered, found := prefs.get(&app.prefs, DEALS_LIST_PREF); found {
		show_scenario_list(app, remembered != "closed")
	}
	draw_deal_bar(app)
}

// The view a tab selects, from its `data-view`. The document names the view and this is the only place that
// spelling is decoded, so a new place is a tab plus an enum member and no new click case.
view_of :: proc(name: string) -> (view: View, ok: bool) {
	switch name {
	case "panes":
		return .Panes, true
	case "editor":
		return .Editor, true
	}
	return .Panes, false
}

// Which view is on screen. Read from the document rather than remembered — same reason as
// `effective_display_is_hidden`.
current_view :: proc(app: ^App) -> View {
	if !effective_display_is_hidden(app, "#about-panel") {
		return .About
	}
	if !effective_display_is_hidden(app, "#editview") {
		return .Editor
	}
	return .Panes
}

// ---------------------------------------------------------------------------------------------------
// The hand page, in the window
//
// `<frame>` is Sciter's sub-document element and the frame BEHAVIOR is host-callable: `loadHtml` takes the
// document as a string (measured — no temp file, no `file://` round trip) and `loadFile` takes a path, for
// the pages a generate run has already written. The framed document is a document of its own: it gets its
// own stylesheet and its own script, and `frame.document` is the way back into it.
//
// The page is the norn card page, written for a browser. It lays out here because of the `@media sciter`
// block in `norn/html_cards_header.html.tmpl`. Lose that block and the page still LOADS — it just lays out
// wrong, which is the failure mode to recognise: hands 950px tall (a unitless `line-height` resolves
// against the viewport) and a board 71px wide (`width: fit-content` collapses). `just page-check` is the
// automated guard for exactly that, including a `-unported` run that proves those numbers can fail.

// Load a document into the frame from memory and show it. False if the frame or its behavior is not there,
// which is a document/CSS problem rather than a page problem — hence the caller's status message.
show_page_html :: proc(app: ^App, html: string, title: string) -> bool {
	asset := page_frame_asset(app) or_return
	html_value := sa.value_from(html)
	defer sa.value_clear(&html_value)
	// The base URL a relative link in the page would resolve against. The page is self-contained, so this
	// only ever shows up in the engine's own diagnostics — which is a reason to make it say where it came
	// from rather than to leave it empty.
	base := sa.value_from("file://workbench/analysed-deal.html")
	defer sa.value_clear(&base)

	result, err := sa.asset_call(asset, "loadHtml", {html_value, base})
	defer sa.value_clear(&result)
	if err != nil || sa.value_is_error(&result) {
		return false
	}
	set_text_at(app, "#page-title", title)
	page_ready(app, true)
	// The pane OPENS itself when a page arrives: pressing generate and then having to press something else
	// to see the result is a step with no decision in it. Closing it stays a decision.
	show_page_pane(app, true)
	return true
}

// The same, for a page a generate run wrote. `loadFile` rather than reading the file here: the engine
// resolves the path, and a page too big to want in memory twice is exactly what a batch produces.
show_page_file :: proc(app: ^App, path: string) -> bool {
	asset := page_frame_asset(app) or_return
	path_value := sa.value_from(path)
	defer sa.value_clear(&path_value)

	result, err := sa.asset_call(asset, "loadFile", {path_value})
	defer sa.value_clear(&result)
	if err != nil || sa.value_is_error(&result) {
		return false
	}
	set_text_at(app, "#page-title", path)
	page_ready(app, true)
	show_page_pane(app, true)
	return true
}

// Give the framed document the keyboard, so the page's own shortcuts work the moment it appears: left/right
// step through the boards, a/n/e/s/w pick a seat. Without this the focus is still on whatever button was
// pressed in the outer document, the page never sees a key, and the arrows read as unimplemented — they work
// in a browser because there the page IS the window.
//
// It has to be an element INSIDE the sub-document, not the `<frame>`: measured, a key only reaches a
// document once something in it holds the focus, and focusing the frame itself is not that. The body is the
// least surprising choice — it is what a click on the page's background would focus.
focus_page :: proc(app: ^App) {
	asset, ok := page_frame_asset(app)
	if !ok {
		return
	}
	document, derr := sa.asset_get(asset, "document")
	defer sa.value_clear(&document)
	if derr != nil {
		return
	}
	root, rerr := sa.element_from_value(&document)
	if rerr != nil {
		return
	}
	if body, berr := sa.select_first(root, "body"); berr == nil {
		sa.set_focus(body)
	}
}

// ---------------------------------------------------------------------------------------------------
// The BML editor
//
// The notes this repository IS, editable in the window that generates deals from them, with the rendered
// page beside the source. `.bml` is the source language of every system document here; `just bml` builds
// the corpus to html, and until now looking at a change meant saving, building and opening a browser.
//
// The rendering is IN-PROCESS, which is the whole reason this is possible: `bridge-markup` (the Odin
// implementation of BML, `markup:.`, the same library `bml2html.odin` drives) parses SOURCE TEXT. The
// python reference renders a FILE — `content_from_file` takes a path — so a preview of text nobody has
// saved has nothing to hand it, and its parse state lives in module globals besides. One parse is ~2ms for
// a chapter, so the preview is a button and not a job: no worker, no progress, no cancel.
//
// The COLOUR is not here. Marks are applied to a `Range` over a text node and that API exists only in the
// document's own runtime, so the colorizer is the one script in `ui/workbench.html` and this side calls it
// (`colorize_bml`) after it writes the buffer — there is no event for a `content=` write.
//
// THE PREVIEW IS LIVE once it is up: it re-renders when the typing stops, on a debounce scaled by what the
// last render cost (`live_preview_delay`, `WORKBENCH_LIVE_MS`). A render per keystroke is not on the table -
// it is a whole document built and laid out, 100ms for a chapter and ~1s for the assembled root.
//
// What is deliberately NOT in this editor: no file dialog (the corpus is a known directory — `docs`), no
// tabs, no undo beyond the widget's own, and no autosave. `save` overwrites the file it loaded, and says
// which one and how many bytes.

// How the corpus is recognised: the root document every chapter is included into. Naming a FILE rather
// than looking for `*.bml` is what keeps `deal-simulations/` — or any other directory that happens to hold
// one — from being mistaken for the notes.
BML_CORPUS_MARKER :: "bidding-system.bml"

// Where the `.bml` corpus is, and a note when it was not found.
//
// `BML_DOCS_DIRECTORY` first, the same variable the quiz app reads for the same purpose. Then a walk UP
// from the working directory, because that is where this program starts: `just sims workbench` starts it in
// `deal-simulations/odin-sims`, two levels below the notes, and the built exe in `target/release`, four.
// Eight levels is more than either needs, and the walk stops at a drive root regardless.
bml_docs_dir :: proc(allocator := context.allocator) -> (dir: string, note: string) {
	if named := os.get_env("BML_DOCS_DIRECTORY", context.temp_allocator); named != "" {
		if bml_corpus_at(named) {
			return strings.clone(named, allocator), ""
		}
		return "", fmt.tprintf(
			"BML_DOCS_DIRECTORY=%s holds no %s — the bml editor has nothing to open",
			named,
			BML_CORPUS_MARKER,
		)
	}

	here, err := filepath.abs(".", context.temp_allocator)
	if err != nil {
		return "", "could not resolve the working directory — the bml editor has nothing to open"
	}
	// `filepath.dir` has no allocator parameter and takes the context's, so the walk below would leave one
	// heap string per level behind. Redirecting the context's allocator at scratch is the whole fix — the
	// two strings that outlive this procedure are cloned into the caller's `allocator` explicitly.
	context.allocator = context.temp_allocator
	walk := here
	for _ in 0 ..< 8 {
		if bml_corpus_at(walk) {
			return strings.clone(walk, allocator), ""
		}
		parent := filepath.dir(walk)
		if parent == walk { 	// a drive root, and it is not the corpus
			break
		}
		walk = parent
	}
	return "", fmt.tprintf(
		"no %s above %s — the bml editor has nothing to open (set BML_DOCS_DIRECTORY)",
		BML_CORPUS_MARKER,
		here,
	)
}

bml_corpus_at :: proc(dir: string) -> bool {
	marker, err := filepath.join({dir, BML_CORPUS_MARKER}, context.temp_allocator)
	return err == nil && os.exists(marker)
}

// The `.bml` files in `dir`, by name, sorted. Names rather than paths: the name is what the picker shows,
// what `bml_open` remembers and what `save` rejoins with `docs` — one directory, decided once.
list_bml_files :: proc(dir: string, allocator := context.allocator) -> []string {
	if dir == "" {
		return nil
	}
	infos, err := os.read_directory_by_path(dir, 0, context.temp_allocator)
	if err != nil {
		return nil
	}
	names := make([dynamic]string, 0, len(infos), allocator)
	for info in infos {
		if info.type == .Directory || !strings.has_suffix(info.name, ".bml") {
			continue
		}
		append(&names, strings.clone(info.name, allocator))
	}
	slice.sort(names[:])
	return names[:]
}

// The file list, and the folder above it. One row per file carrying its NAME — `data-file` rather than an
// index, because the list is re-read whenever the folder changes and an index would silently point at a
// different file. Same shape as `draw_scenarios`, including `escape_html` on everything: `set_html` is a
// parser, and a filename is not ours to trust even when it is.
//
// The row for the open file is marked, and marked DIRTY when the buffer has unsaved changes, so the warning
// is on the thing that would lose them rather than only in the status line.
draw_bml_files :: proc(app: ^App) {
	folder := app.docs if app.docs != "" else "no folder chosen"
	set_text_at(app, "#bml-dir", folder)
	// The path is also the tooltip, because a long one wraps to two or three lines in a 250px column and
	// hovering is then the only way to read it as one string (to copy it, or to tell two checkouts apart).
	if head := find(app, "#bml-dir"); head != nil {
		sa.set_attribute(head, "title", folder)
	}

	list := find(app, "#bml-list")
	if list == nil {
		return
	}
	if len(app.bml_names) == 0 {
		sa.set_html(list, `<div class="empty">no .bml files here</div>`)
		return
	}
	modified := app.bml_open != "" && bml_modified(app)
	b := strings.builder_make(context.temp_allocator)
	for name in app.bml_names {
		escaped := escape_html(name, context.temp_allocator)
		classes := "row"
		if name == app.bml_open {
			classes = "row sel dirty" if modified else "row sel"
		}
		fmt.sbprintf(&b, `<div class="%s" data-file="%s">%s</div>`, classes, escaped, escaped)
	}
	sa.set_html(list, strings.to_string(b))
}

// Open the editor view, loading the first file the first time. Later visits leave the buffer alone: the text
// someone was editing is the thing they came back to.
//
// A MISSING CORPUS NO LONGER REFUSES. It used to say "set BML_DOCS_DIRECTORY" and stay on the deals, which
// named an environment variable at somebody holding a mouse; now the view opens with an empty list and the
// `folder…` button in it, which is the thing to press. The startup search is a convenience, not the only
// way in.
show_editor :: proc(app: ^App) {
	show_view(app, .Editor)
	draw_bml_files(app)
	if app.docs == "" || len(app.bml_names) == 0 {
		bml_status(app, "choose a folder of .bml files")
		return
	}
	if app.bml_open == "" {
		ok, why := open_bml(app, app.bml_names[0])
		if !ok {
			bml_status(app, why)
			return
		}
	}
	// And the source pane takes the FOCUS. Without it the view opens with the text on screen and nothing in
	// the window holding the caret, which is a pane that answers no keystroke until it is clicked — read,
	// reasonably, as a viewer rather than an editor. The engine only paints a caret in a focused widget.
	if text := find(app, "#bml-text"); text != nil {
		_ = sa.set_focus(text)
	}
}

// The native folder dialog, and the ONLY route to one: file and folder dialogs have no host API in this
// engine — `Window.this` in the document's own runtime is the only object that reaches them (odin-sciter
// docs/JS-RUNTIME.md, SDK-PARITY.md). So the host asks the document to ask the engine.
//
// It returns a folder URL (`file:///C:/...`), not a path, which is the same percent-encoded shape a dropped
// file arrives as — so it goes through the same `file_url_to_path`. A cancelled dialog returns nothing and
// nothing happens, which is what a cancel should do.
//
// This call BLOCKS in the modal dialog, so nothing tests it. What is testable is everything after it, which
// is why `use_bml_dir` is a procedure of its own.
choose_bml_folder :: proc(app: ^App) {
	script := `(function () {
		var picked = Window.this.selectFolder({ caption: "Choose a folder of .bml notes" });
		return picked ? String(picked) : "";
	})()`
	result, err := sa.eval(app.window, script)
	defer sa.value_clear(&result)
	if err != nil {
		bml_status(app, "this build cannot open a folder dialog")
		log.warnf("selectFolder did not run: %v", err)
		return
	}
	url, serr := sa.value_to_string(&result, context.temp_allocator)
	if serr != nil || url == "" {
		return // cancelled
	}
	path, ok := file_url_to_path(url, context.temp_allocator)
	if !ok {
		bml_status(app, fmt.tprintf("could not read that folder's path (%s)", url))
		return
	}
	use_bml_dir(app, path)
}

// Point the editor at a folder. Everything that follows a folder being chosen, by dialog or otherwise, and
// the reason it is separate from the dialog that blocks.
//
// A folder with no `.bml` in it is REPORTED AND KEPT rather than refused: the list says "no .bml files here"
// under the folder's own name, which is the answer to "did it not work, or is it empty?". What is not kept
// is the open buffer — the file it came from is not in this folder.
use_bml_dir :: proc(app: ^App, path: string) {
	names := list_bml_files(path, app.allocator)

	// The palette's index names the files of the folder being LEFT, so it goes with them; it is rebuilt the
	// next time the palette is opened.
	close_goto(app)
	free_goto_index(app)

	for name in app.bml_names {
		delete(name, app.allocator)
	}
	delete(app.bml_names, app.allocator)
	delete(app.docs, app.allocator)
	delete(app.bml_open, app.allocator)

	app.docs = strings.clone(path, app.allocator)
	app.bml_names = names
	app.bml_open = ""
	app.bml_armed = false
	app.previewed = false // whatever is in the frame belongs to the folder we just left
	set_bml_source(app, "")
	draw_bml_files(app)

	if len(names) == 0 {
		bml_status(app, fmt.tprintf("no .bml files in %s", path))
		return
	}
	ok, why := open_bml(app, names[0])
	if !ok {
		bml_status(app, why)
	}
}

// Load one file into the editor. The name is remembered rather than the path, and the LINE ENDINGS it
// arrived with are remembered too: the corpus is CRLF, the widget hands its content back as `\n`, and
// saving LF would rewrite every line of a file whose only real change was one word.
open_bml :: proc(app: ^App, name: string, repreview := true) -> (ok: bool, why: string) {
	path, jerr := filepath.join({app.docs, name}, context.temp_allocator)
	if jerr != nil {
		return false, fmt.tprintf("could not resolve %s", name)
	}
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		return false, fmt.tprintf("could not read %s: %v", name, rerr)
	}
	source := string(data)

	delete(app.bml_open, app.allocator)
	app.bml_open = strings.clone(name, app.allocator)
	// A new file gets its own scope decision: what was remembered for THIS file, else what its size suggests.
	app.bml_scope_set = false
	app.bml_crlf = strings.contains(source, "\r\n")
	app.bml_armed = false

	// `\n` for the widget whatever the file holds, and no trailing blank line: a trailing newline becomes
	// an extra line the plaintext then reports at the FRONT of its content (measured — see
	// `draw_transcript`), so it would come back on save as a blank first line.
	text := source
	if app.bml_crlf {
		text, _ = strings.replace_all(source, "\r\n", "\n", context.temp_allocator)
	}
	set_bml_source(app, strings.trim_right(text, "\n"))
	colorize_bml(app)
	// The text in the widget is not the text the last parse saw, so nothing that was marked still applies.
	clear_bml_problems(app)
	draw_bml_files(app)
	// The file, and not the folder: the folder is named above the list, and saying it twice cost the status
	// line the room it needs for what actually happened next (previewed, saved, refused).
	bml_status(app, name)

	// A preview ON SCREEN is showing the file that WAS open. Re-render it rather than leaving it: the panes
	// are side by side and nothing in the window would say the right-hand one is a file behind. Only when
	// one is up — the first preview stays something you ask for, and a CLOSED preview stays closed (and
	// costs nothing) until it is asked for again.
	// `repreview = false` is for a caller that is about to move the caret and re-render anyway - the heading
	// palette. Rendering here as well would render the whole document TWICE for one jump, at the wrong
	// caret, and on the assembled root that is a few hundred MB and most of a second each time.
	if repreview && app.previewed && app.bml_showing {
		if rendered, reason := preview_bml(app); !rendered {
			bml_status(app, reason)
		}
	}
	return true, ""
}

// Write the buffer back to the file it came from. The one destructive thing in this window, so it says what
// it wrote — and it restores the file's own line endings and its single trailing newline rather than
// imposing the widget's.
save_bml :: proc(app: ^App) -> (ok: bool, why: string) {
	if app.bml_open == "" {
		return false, "nothing is open"
	}
	text, got := bml_source(app, context.temp_allocator)
	if !got {
		return false, "the editor's text could not be read"
	}
	body := strings.concatenate({strings.trim_right(text, "\n"), "\n"}, context.temp_allocator)
	if app.bml_crlf {
		body, _ = strings.replace_all(body, "\n", "\r\n", context.temp_allocator)
	}
	path, jerr := filepath.join({app.docs, app.bml_open}, context.temp_allocator)
	if jerr != nil {
		return false, fmt.tprintf("could not resolve %s", app.bml_open)
	}
	if werr := os.write_entire_file(path, transmute([]u8)body); werr != nil {
		return false, fmt.tprintf("could not write %s: %v", app.bml_open, werr)
	}
	app.bml_armed = false
	return true, fmt.tprintf("saved %s · %d bytes", app.bml_open, len(body))
}

// Render what is IN THE EDITOR — not what is on disk — into the preview frame.
//
// The library's diagnostics are reported rather than swallowed: a mistyped `#INCLUDE` renders a document
// that is merely missing a chapter, which is exactly the kind of thing a preview should say out loud.
preview_bml :: proc(app: ^App) -> (ok: bool, why: string) {
	// NOT RE-ENTRANT, and it cannot be: building the document in the frame pumps the engine, so a timer or a
	// click delivered inside that pump would start a second render into the same frame. The guard is here
	// rather than in the live path so it covers every caller - the button, the fold, the palette`s jump.
	if app.bml_rendering {
		return false, "the preview is still rendering"
	}
	app.bml_rendering = true
	defer app.bml_rendering = false
	started := time.tick_now()

	source, got := bml_source(app, context.temp_allocator)
	if !got {
		return false, "the editor's text could not be read"
	}
	// What the render COST, which is what the live preview scales its debounce by. Written on the way out so
	// it includes the document build and the scroll, not just the parse.
	defer app.bml_preview_cost = time.tick_since(started)
	doc := bml.parse(
		source,
		{resolve_include = bml_include, include_user = app, check_cross_references = app.bml_links},
	)
	defer bml.destroy(doc)

	html := bml.render_html(doc, context.temp_allocator)

	// Which section to show: the one the caret is in, decided on the SOURCE, because the headings in the
	// buffer are in the same order as the headings in the page - counting them is the whole mapping, with no
	// line numbers in the html and nothing to keep in step. `full` turns the parking off with a -1.
	// The scope, then the section. Decided ONCE per file - what was remembered for it, else what its SIZE
	// suggests (a 17KB chapter whole, the 1.18MB assembled root on one section) - because after that the
	// buttons own it.
	if !app.bml_scope_set {
		app.bml_scope = scope_for_file(app, app.bml_open, html)
		app.bml_scope_set = true
	}
	show_scope_buttons(app)

	sections := preview.section_count(html)
	section := -1
	if app.bml_scope == .Folded && sections > 1 {
		section = preview.section_of_row(source, caret_row(app))
	}

	page := preview_document(app, html, section, context.temp_allocator)
	if !show_preview_html(app, page) {
		return false, "the preview could not be loaded into the frame"
	}
	app.previewed = true
	// And a fingerprint of the text the pane is NOW showing, so a debounce that fires over an untouched
	// buffer costs nothing. After the load rather than before it: a render that failed has not been seen, and
	// recording it here would leave the live preview waiting for a second edit before trying again.
	app.bml_rendered = hash.fnv64a(transmute([]u8)source)

	// THE PANE IS SHOWN BEFORE THE DIAGNOSTICS ARE REPORTED, and that order is load-bearing twice over.
	// It used to be the other way round, and a document with ANY diagnostic in it returned from here before
	// the pane was ever shown - so a chapter with one mistyped directive rendered into a frame nobody could
	// see, which reads as "preview does nothing on this file". And the scroll below needs the frame to be
	// on screen: a `display: none` frame has no layout, so nothing can be measured or scrolled in it.
	app.bml_showing = true
	set_shown(app, "#bml-page", true)
	show_preview_button(app)
	follow_preview_to_caret(app)

	// The diagnostics are squiggled on the text they are about AND written to the transcript: the marks say
	// where, the transcript says what, and a problem inside an INCLUDED file has no line in this buffer to
	// point at, so the transcript is the only place it can be reported at all.
	marked := show_bml_problems(app, doc.diagnostics)
	for diagnostic in doc.diagnostics {
		transcribe(app, bml.diagnostic_text(diagnostic, context.temp_allocator))
	}
	if len(doc.diagnostics) > 0 {
		return true, fmt.tprintf(
			"%s · %s · %d marked",
			app.bml_open,
			bml.diagnostic_text(doc.diagnostics[0], context.temp_allocator),
			marked,
		)
	}
	// The status says what is OPEN inside the fold, not merely that folding is on: the window grows forward
	// until there is something to read, so naming one section while three are open would be a lie.
	scope := "unfolded"
	if section >= 0 {
		first, last := preview.section_window(html, section)
		scope =
			first == last ? fmt.tprintf("folded · section %d of %d open", first + 1, sections) : fmt.tprintf("folded · sections %d-%d of %d open", first + 1, last + 1, sections)
	}
	return true, fmt.tprintf("%s · previewed %d blocks · %s", app.bml_open, len(doc.blocks), scope)
}

// `#INCLUDE name`: the corpus directory first, then the working directory. The other way round from
// `bml2html.odin`, and deliberately — that program is the reference's stand-in and the reference resolves
// against the cwd, whereas here the file being edited is known to live in `docs` and the cwd is wherever
// the exe happened to start. A miss is a diagnostic inside the library rather than an error: a half-typed
// document has to keep rendering.
bml_include :: proc(name: string, user: rawptr, allocator: mem.Allocator) -> (text: string, ok: bool) {
	app := cast(^App)user
	if app != nil && app.docs != "" {
		if path, jerr := filepath.join({app.docs, name}, context.temp_allocator); jerr == nil {
			if data, err := os.read_entire_file_from_path(path, allocator); err == nil {
				return string(data), true
			}
		}
	}
	data, err := os.read_entire_file_from_path(name, allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

/*
Which section of the notes the caret is in, so the preview can show that one and park the rest.

The row comes from the widget's own `selectionStart`, which is an ARRAY - `[row, column]` - reachable
through the plaintext asset rather than from script (measured: `element.selectionStart` in script is
`undefined`; the behavior publishes it as a SOM member, the same door `isModified` comes through).

Returns 0 when there is no caret to ask about, which is the top of the document: a preview of the first
section is a reasonable thing to be looking at before you have clicked anywhere.
*/
caret_row :: proc(app: ^App) -> int {
	element := find(app, "#bml-text")
	if element == nil {
		return 0
	}
	asset, aerr := sa.element_asset(element, "plaintext")
	if aerr != nil {
		return 0
	}
	value, gerr := sa.asset_get(asset, "selectionStart")
	if gerr != nil {
		return 0
	}
	defer sa.value_clear(&value)
	if kind, _ := sa.value_type(&value); kind != .ARRAY {
		return 0
	}
	row, rerr := sa.value_at(&value, 0)
	if rerr != nil {
		return 0
	}
	defer sa.value_clear(&row)
	number, ierr := sa.value_to_int(&row)
	return ierr == nil ? int(number) : 0
}

/*
How much of the notes the preview shows, and how that is decided.

Two states, both named in the bar (`section` / `whole`) rather than one button whose label has to be read as
a promise about what pressing it will do. They are mutually exclusive and the active one is marked, which is
the only shape that answers "what am I looking at" and "what else is there" at the same time.

THE DEFAULT IS THE DOCUMENT'S SIZE, not a fixed choice, because the corpus is not uniform: most chapters
render to 4-36KB and cost a few MB whole, while `uncontested-bidding.bml` is 316KB and the assembled root is
1.18MB / 328MB. `preview.fits_whole` draws that line at 64KB (~16MB). So a small chapter opens whole - which
is what a person expects when they click a file with three headings in it - and only the big ones open on one
section.

AND THE CHOICE IS REMEMBERED PER FILE, in `prefs`, because it is a property of the document a person is
working on rather than of the session: a chapter you always read whole should not need saying twice. An
explicit press is what gets remembered; the size-based default is not written down, so a file that grows past
the threshold starts sectioning itself without having to be told.
*/
Preview_Scope :: enum {
	Folded,
	Unfolded,
}

@(private = "file")
SCOPE_PREF_PREFIX :: "preview.fold."

// The scope for a file: what was chosen for it before, else what its size suggests.
scope_for_file :: proc(app: ^App, name: string, html: string) -> Preview_Scope {
	if name != "" {
		if remembered, found := prefs.get(&app.prefs, scope_key(name)); found {
			return remembered == "unfolded" ? .Unfolded : .Folded
		}
	}
	return preview.fits_whole(html) ? .Unfolded : .Folded
}

@(private = "file")
scope_key :: proc(name: string) -> string {
	return fmt.tprintf("%s%s", SCOPE_PREF_PREFIX, name)
}

// Remember an explicit choice for the open file, and put it on disk now rather than at exit: the window is
// closed by killing it as often as not, and a preference that only survives a graceful exit is a lottery.
remember_scope :: proc(app: ^App) {
	// No file, or no store (a test's App has none): the choice still applies to this session, it is just not
	// written down. Setting a key on a nil map would be the alternative, and that is a crash.
	if app.bml_open == "" || app.prefs.values == nil {
		return
	}
	prefs.set(&app.prefs, scope_key(app.bml_open), app.bml_scope == .Unfolded ? "unfolded" : "folded")
	if app.prefs_path != "" {
		_ = prefs.save(&app.prefs, app.prefs_path)
	}
}

/*
ONE control, marked when it is doing something - the same shape as `links` beside it.

Two buttons (`section` / `whole`) were the first attempt and they read as two unrelated commands rather than
as two halves of a state, which is exactly what was reported. A single `fold` that is lit when the document
is folded says what state the preview is in, and pressing it is the way out of that state.
*/
show_scope_buttons :: proc(app: ^App) {
	// The label is the ACTION, not the state: `fold` while the document is unfolded, `unfold` while it is
	// folded. A lit button says "something is on" and leaves the way out to be guessed; a verb does not.
	set_text_at(app, "#bml-fold", app.bml_scope == .Folded ? "unfold" : "fold")
	mark_toggle(app, "#bml-fold", app.bml_scope == .Folded)
}

/*
Close the preview: hide the pane, and give the engine the document back.

The hiding is the visible half and the cheap half. The other half is `loadHtml` with a blank page into the
frame, and it is the point: a rendered page is the most expensive thing in this window (a chapter is tens of
MB, the assembled system 328 - `preview/preview.odin`), the engine returns all of it when the document is
replaced (measured), and a pane nobody is looking at has no business holding it.

`app.previewed` is deliberately LEFT SET: it means "a preview has been asked for", which is what makes the
next file click re-render rather than sit there showing nothing. `bml_showing` is the pane's own state.
*/
close_preview :: proc(app: ^App) {
	app.bml_showing = false
	set_shown(app, "#bml-page", false)
	_ = show_preview_html(app, "<html><body></body></html>")
	show_preview_button(app)
}

// The preview button says which of its two jobs a press will do. Written here rather than in the document,
// because the state it names is the host's.
show_preview_button :: proc(app: ^App) {
	set_text_at(app, "#bml-preview", app.bml_showing ? "close" : "preview")
}

// The preview document: the library's html made SELF-CONTAINED.
//
// What comes out of `render_html` is a page for a web server — it `<link>`s `bml.css` relatively and pulls
// a webfont over https. Neither belongs in a desktop window: the relative link would resolve against a
// base url this frame does not have, and the font request is an outbound connection an offline app should
// not be making (odin-sciter's release checklist says so). So every `<link>` goes and the stylesheet is
// inlined instead. `bml.css` is ~6.6 KB, well under the 32 KiB an inline `<style>` is capped at in this
// engine — and past that cap the WHOLE block is discarded, first rule included, so the number matters.
preview_document :: proc(app: ^App, html: string, section := -1, allocator := context.allocator) -> string {
	css := ""
	if app.docs != "" {
		if path, jerr := filepath.join({app.docs, "bml.css"}, context.temp_allocator); jerr == nil {
			if data, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
				css = string(data)
			}
		}
	}
	stripped := strip_link_tags(html, context.temp_allocator)
	head := strings.index(stripped, "<head>")
	if head < 0 { 	// no head to put a stylesheet in: hand back the markup rather than mangling it
		return strings.clone(stripped, allocator)
	}
	cut := head + len("<head>")
	b := strings.builder_make(allocator)
	strings.write_string(&b, stripped[:cut])
	strings.write_string(&b, "<style>")
	strings.write_string(&b, strip_width_media_blocks(css, context.temp_allocator))
	strings.write_string(&b, "</style>")
	strings.write_string(&b, preview_override_css(css, context.temp_allocator))

	/*
	The rest of the document, CUT DOWN to the section being edited (`section < 0` keeps all of it).

	Cut in the text rather than hidden in the document, and that distinction was measured: hiding the other
	sections with `display: none` from a script cost MORE than leaving them alone (434MB against 330MB),
	because a document is laid out at load before any script of ours runs - so hiding pays for the layout and
	for the hidden state, and gets none of the first payment back. `preview/preview.odin` has the numbers.
	*/
	body := stripped[cut:]
	if section >= 0 {
		// FOLDED: every heading stays, one section is open, the other bodies become `…`. Not a slice - the
		// outline is what a preview is for, and it costs two boxes a section.
		body = preview.fold_document(body, section, allocator = context.temp_allocator)
	}
	strings.write_string(&b, body)
	return strings.to_string(b)
}

// The one thing the preview adds to the notes' own stylesheet, in a `<style>` of its own so it lands after
// it whatever that sheet does.
//
// The one thing the preview adds, in a `<style>` of its own so it lands after the sheet whatever that sheet
// does. It fixes ONE thing, and the reason is worth writing down because the page is not wrong — a browser
// is doing something for it that this engine does not.
//
// In the notes' html the BODY IS THE CONTENT COLUMN: `<body class="content">`, and `.content` is
// `max-width: 900px; margin: auto`. So the body box is 900px in a 1120px view (measured: 901 of 1121), and
// its `background: antiquewhite` paints 900px of cream with white either side. A BROWSER never shows that,
// because a browser propagates the body background to the canvas behind the whole viewport. Sciter paints
// the body box and no more.
//
// So the ROOT is what gets painted, with the body's own colour — DERIVED from the sheet rather than written
// out here, because a copy of a colour in a second file is a thing that goes stale silently. `size: *` on
// the root as well: it is how a Sciter box fills what is left, and an unsized root would shrink to its
// content and take the paint with it.
//
// The column stays a column: `max-width` still caps the body, so the preview keeps the shape the published
// page has, on cream that now reaches both edges.
preview_override_css :: proc(css: string, allocator := context.allocator) -> string {
	background := preview_page_background(css)
	if background == "" {
		// Nothing to mirror: fill the body instead, so a sheet with no page colour of its own at least has
		// no white gutters where its text is.
		return strings.clone("<style>html { size: *; } body { size: *; max-width: none; }</style>", allocator)
	}
	// CONCATENATED, not formatted: `fmt` reads a brace as a directive, and a CSS rule is nothing but
	// braces — the printf version emitted `html %!(MISSING CLOSE BRACE)size: *` and the sheet was junk the
	// engine silently ignored.
	// `.wb-folded` is the ellipsis a folded section's body is replaced by (`preview.FOLD_PLACEHOLDER`):
	// dimmed, so the outline reads as an outline rather than as a document full of stray dots.
	return strings.concatenate(
		{
			"<style>html { size: *; background: ",
			background,
			"; } body { size: *; } .wb-folded { color: #8a8a8a; margin: 2px 0 10px 0; }</style>",
		},
		allocator,
	)
}

// The page background the notes' stylesheet gives the body, as a CSS value, or "" if it names none.
//
// A scan of the FIRST `body { … }` rule rather than a parser, and `background` or `background-color`
// whichever comes first — this reads one known sheet (`bml.css`), and a wrong answer costs the preview a
// tinted gutter, not correctness. `!important`, comments and shorthand values are left as written: whatever
// the sheet said is handed to the same engine that was going to read it anyway.
preview_page_background :: proc(css: string) -> string {
	rest := css
	for {
		at := strings.index(rest, "body")
		if at < 0 {
			return ""
		}
		rest = rest[at + len("body"):]
		open := strings.index_byte(rest, '{')
		close := strings.index_byte(rest, '}')
		if open < 0 || close < 0 || close < open {
			continue // not a rule: `body` inside a selector list or a comment
		}
		// Anything but whitespace between the name and the brace means this was a compound selector
		// (`body.content`, `body >`, `html, body`), which is not the rule wanted here.
		if strings.trim_space(rest[:open]) != "" {
			continue
		}
		for declaration in strings.split(rest[open + 1:][:close - open - 1], ";", context.temp_allocator) {
			colon := strings.index_byte(declaration, ':')
			if colon < 0 {
				continue
			}
			property := strings.trim_space(declaration[:colon])
			if property == "background" || property == "background-color" {
				return strings.trim_space(declaration[colon + 1:])
			}
		}
		return "" // the body rule was found and it names no background
	}
}

// EVERY `@media` BLOCK WITH A WIDTH FEATURE, REMOVED — because it CRASHES THE ENGINE.
//
// Measured by bisection in a windowless view (`test_width_media_blocks_are_stripped` is what keeps the
// stripper honest; the crash itself cannot be a test — it takes the runner with it): a document loaded into a `<frame>` whose stylesheet contains `@media (max-width: 699px)`,
// `@media all and (max-width: 699px)`, or the `(min-width: …) and (max-width: …)` range takes the process
// down with a caught signal. `@media all` and `@media screen` — a bare media TYPE, no feature — are fine,
// so it is the width feature and not the at-rule.
//
// The card page's port note records the same construct as a PARSE ERROR that discards the rest of the
// stylesheet, which is the milder face of this: either way the notes' responsive `.content` widths never
// run here. Removing the blocks costs the preview nothing it had — and it gains the base
// `.content { max-width: 900px }`, which is the browser's look at any width the window can be.
//
// Brace-matched rather than pattern-matched, and only `@media` is touched: the sheet's ordinary rules,
// its `:root` variables and anything else at-rule-shaped are left exactly as they are.
strip_width_media_blocks :: proc(css: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	rest := css
	for {
		at := strings.index(rest, "@media")
		if at < 0 {
			break
		}
		open := strings.index_byte(rest[at:], '{')
		if open < 0 {
			break
		}
		condition := rest[at:][:open]
		if !strings.contains(condition, "width") { 	// a bare media type is safe: keep it
			strings.write_string(&b, rest[:at + open + 1])
			rest = rest[at + open + 1:]
			continue
		}
		// Skip the whole block, counting braces so a nested rule cannot end it early.
		depth := 0
		end := -1
		for i in (at + open) ..< len(rest) {
			switch rest[i] {
			case '{':
				depth += 1
			case '}':
				depth -= 1
				if depth == 0 {
					end = i + 1
				}
			}
			if end >= 0 {
				break
			}
		}
		strings.write_string(&b, rest[:at])
		if end < 0 { 	// unterminated: drop the remainder rather than emit half a block
			rest = ""
			break
		}
		rest = rest[end:]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b)
}

// Every `<link ...>` removed. A scan rather than a parser, because the input is one generator's output and
// the tags it emits are the two named above — but written to drop any of them, so a third could not
// quietly become an http request out of a desktop window.
strip_link_tags :: proc(html: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	rest := html
	for {
		open := strings.index(rest, "<link")
		if open < 0 {
			break
		}
		close := strings.index(rest[open:], ">")
		if close < 0 {
			break
		}
		strings.write_string(&b, rest[:open])
		rest = rest[open + close + 1:]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b)
}

// The preview's own `<frame>`, loaded from memory the way the card page is. It gets a base url all the
// same: it only ever shows up in the engine's diagnostics, and one that says where the document came from
// is worth the line.
show_preview_html :: proc(app: ^App, html: string) -> bool {
	element := find(app, "#bml-page")
	if element == nil {
		return false
	}
	asset, aerr := sa.element_asset(element, "frame")
	if aerr != nil {
		return false
	}
	html_value := sa.value_from(html)
	defer sa.value_clear(&html_value)
	base := sa.value_from("file://workbench/bml-preview.html")
	defer sa.value_clear(&base)

	result, err := sa.asset_call(asset, "loadHtml", {html_value, base})
	defer sa.value_clear(&result)
	return err == nil && !sa.value_is_error(&result)
}

// The buffer, read from the widget's LINES rather than from its `content` property.
//
// `content` is what `report_content` reads and it is good enough there — the transcript is written, never
// read back for anything but a test. For a file that is about to be SAVED it is not usable, and this was
// measured rather than assumed (`test_the_widget_lines_are_the_buffer` pins it):
//
//	written "a\nb\nc"  ->  content reads back "\r\na\r\nbc"
//
// The separator is emitted BEFORE each line instead of after it, so the content gains a blank first line —
// the symptom `draw_transcript` works around from the writing side — and, worse, the LAST boundary is
// missing entirely: the final two lines arrive joined, and no amount of splitting recovers them. Saving
// through that would silently glue the last two lines of the file together.
//
// The `<text>` children are exact: one per line, in order, `sa.text` giving the line. Both `\n` and `\r\n`
// are accepted on the way IN, so only this direction needs the care. ~5000 calls for the largest chapter,
// on a button press.
bml_source :: proc(app: ^App, allocator := context.allocator) -> (text: string, ok: bool) {
	element := find(app, "#bml-text")
	if element == nil {
		return "", false
	}
	b := strings.builder_make(allocator)
	for n := 0;; n += 1 {
		child, cerr := sa.child(element, sa.Child_Index(n))
		if cerr != nil || child == nil {
			break
		}
		if n > 0 {
			strings.write_byte(&b, '\n')
		}
		line, terr := sa.text(child, context.temp_allocator)
		if terr == nil {
			strings.write_string(&b, line)
		}
	}
	return strings.to_string(b), true
}

set_bml_source :: proc(app: ^App, text: string) {
	element := find(app, "#bml-text")
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

// Has the buffer been edited since it was loaded or saved? The widget's own flag (`isModified`), so
// nothing here keeps a shadow copy of the text to compare against.
bml_modified :: proc(app: ^App) -> bool {
	element := find(app, "#bml-text")
	if element == nil {
		return false
	}
	asset, aerr := sa.element_asset(element, "plaintext")
	if aerr != nil {
		return false
	}
	value, gerr := sa.asset_get(asset, "isModified")
	if gerr != nil {
		return false
	}
	defer sa.value_clear(&value)
	modified, berr := sa.value_to_bool(&value)
	return berr == nil && modified
}

// Colour the buffer. The document's own script does the work (see the comment at the top of this section);
// this is the call, and it is needed because a host-side `content=` write raises no `change` event for the
// script to hang a colorize off.
// Hands back the number of marks it applied, which is the only thing this side can see of the result: a
// mark leaves no attribute behind and reads back through a `Range` or not at all. Zero from a buffer with
// text in it means the script did not run, and `test_the_bml_editor_colours_what_it_loads` says so.
colorize_bml :: proc(app: ^App) -> int {
	result, err := sa.eval(app.window, "bmlColorize()")
	defer sa.value_clear(&result)
	if err != nil {
		log.warnf("the bml colorizer did not run: %v", err)
		return 0
	}
	marks, ierr := sa.value_to_int(&result)
	if ierr != nil {
		return 0
	}
	return int(marks)
}

/*
Squiggle the parse's diagnostics on the text they are about, and say how many marks landed.

The marking happens in the document, for the same reason the colouring does: a mark is applied to a `Range`
over a text node and the host bindings have no `Range`. So this composes the positions into json and hands
them over. The count comes back because a mark leaves NOTHING on the element - it reads back through a
`Range` or not at all - and it is not the same as the number of diagnostics: one that points into an
INCLUDED file, or past the end of the buffer, has no line here to mark and is dropped by the script rather
than clamped onto an innocent line.

`bml.Severity` is spelled out rather than sent as a number: the two ends are in different languages, and a
bare `0` is a fine way to get the colours backwards the day a third severity is added.

The json is assembled with plain writes rather than a format string on purpose - Odin's `fmt` reads `{` as
a format directive, so a `{"line":` in a format string is not the text it looks like.
*/
show_bml_problems :: proc(app: ^App, diagnostics: []bml.Diagnostic) -> int {
	payload := strings.builder_make(0, 256, context.temp_allocator)
	strings.write_byte(&payload, '[')
	first := true
	for diagnostic in diagnostics {
		// A diagnostic about another file cannot be marked in this buffer; the transcript reports it.
		if diagnostic.file != "" || diagnostic.line <= 0 {
			continue
		}
		if !first {
			strings.write_byte(&payload, ',')
		}
		first = false
		strings.write_string(&payload, `{"line":`)
		strings.write_int(&payload, diagnostic.line)
		strings.write_string(&payload, `,"col":`)
		strings.write_int(&payload, diagnostic.col)
		strings.write_string(&payload, `,"len":`)
		strings.write_int(&payload, diagnostic.length)
		strings.write_string(&payload, `,"severity":`)
		write_json_string(&payload, diagnostic.severity == .Warning ? "warning" : "error")
		strings.write_string(&payload, `,"message":`)
		write_json_string(&payload, diagnostic.message)
		strings.write_byte(&payload, '}')
	}
	strings.write_byte(&payload, ']')

	// The json goes through as a STRING ARGUMENT, not spliced into the script as an array literal: a
	// message quoting the source (`#PASTE "x=" is not target=replacement`) would otherwise need escaping
	// twice, once as json and once as a script literal, and the second is the one everybody forgets.
	script := strings.concatenate(
		{"bmlSetProblems(", json_string(strings.to_string(payload), context.temp_allocator), ")"},
		context.temp_allocator,
	)
	result, err := sa.eval(app.window, script)
	defer sa.value_clear(&result)
	if err != nil {
		log.warnf("the bml diagnostics were not marked: %v", err)
		return 0
	}
	marks, ierr := sa.value_to_int(&result)
	return ierr == nil ? int(marks) : 0
}

// Drop every squiggle. Called when the buffer stops being the text the diagnostics were computed from -
// another file, another folder - because a stale squiggle points confidently at the wrong word.
clear_bml_problems :: proc(app: ^App) {
	result, err := sa.eval(app.window, "bmlClearProblems()")
	sa.value_clear(&result)
	if err != nil {
		log.warnf("the bml diagnostics were not cleared: %v", err)
	}
}

// json's own escaping, which is also a javascript string literal's. Enough for a diagnostic: the control
// characters are escaped and everything else goes through as the utf-8 it already is.
@(private = "file")
write_json_string :: proc(out: ^strings.Builder, text: string) {
	hex := "0123456789abcdef"
	strings.write_byte(out, '"')
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case '"':
			strings.write_string(out, `\"`)
		case '\\':
			strings.write_string(out, `\\`)
		case '\n':
			strings.write_string(out, `\n`)
		case '\r':
			strings.write_string(out, `\r`)
		case '\t':
			strings.write_string(out, `\t`)
		case:
			if c < 0x20 {
				strings.write_string(out, `\u00`)
				strings.write_byte(out, hex[c >> 4])
				strings.write_byte(out, hex[c & 0xf])
			} else {
				strings.write_byte(out, c)
			}
		}
	}
	strings.write_byte(out, '"')
}

@(private = "file")
json_string :: proc(text: string, allocator := context.allocator) -> string {
	out := strings.builder_make(0, len(text) + 16, allocator)
	write_json_string(&out, text)
	return strings.to_string(out)
}

// The editor's own status line, in its own bar. Separate from `#status` in the generate panel: the two
// views are never on screen together, and a message about a file has no business in the panel about deals.
bml_status :: proc(app: ^App, text: string) {
	set_text_at(app, "#bml-status", text)
}

// A file was clicked. Loading it is the obvious thing to do and it is what happens — except over UNSAVED
// text, which would go without a trace and with nothing to undo it from.
//
// The guard is a two-step rather than a dialog: the first attempt to leave an edited buffer is REFUSED and
// the bar says what to do; the next one goes through and discards. No modal and no third button. The list
// never lies about which file is open in the meantime, because the marking comes from `app.bml_open` and
// that is exactly what has not changed.
switch_bml_file :: proc(app: ^App, name: string, repreview := true) {
	if name == "" || name == app.bml_open {
		return
	}
	if app.bml_open != "" && bml_modified(app) && !app.bml_armed {
		app.bml_armed = true
		bml_status(app, fmt.tprintf("%s has unsaved changes — save, or click again to discard them", app.bml_open))
		draw_bml_files(app) // the dot goes on the row that would lose them
		return
	}
	ok, why := open_bml(app, name, repreview)
	if !ok {
		bml_status(app, why)
	}
}

// ---------------------------------------------------------------------------------------------------
// The heading palette: go to any heading in the corpus, by name
//
// CTRL+R in the notes view, then type. This is Sublime Text's `goto symbol` and the muscle memory is the
// reason for the key: the notes ARE the symbols of this repository, and the way anyone refers to a place in
// them is by heading ("Lebensohl", "2NT rebid") rather than by a file and a line. CTRL+F was refused for
// the obvious reason - it means "find text" everywhere - and so was CTRL+O, which means "open" and would be
// a lie for something that never opens a dialog.
//
// It searches the WHOLE corpus rather than the open file, which is what a file list cannot do: the folder's
// other chapters are where half the destinations are, and the row says which file each one is in. The open
// file comes FIRST though, with no query typed at all, because that is where the next jump nearly always
// goes.
//
// The model, the matching and the ranking are in `outline/`, with no engine in them and unit tests of their
// own. What is here is the DOM half: a row of the editor's own flow (NOT an overlay - an out-of-flow
// percentage height lays out 1px tall in this engine, see the CSS header), the keys, and the caret.
//
// The index is built when the palette OPENS - 19 files, ~1MB, ~1000 headings, under a millisecond - rather
// than kept in step with the folder. The alternative is a cache that has to be invalidated by a save, a
// folder change and an edit, and a palette that offers a heading which is no longer there is worse than one
// that costs a millisecond. The file being EDITED is read from the buffer instead of from disk, so a heading
// you have just typed is already a destination.

// How many rows the list shows. A palette is a keyboard control: enough to see that the ranking found the
// right thing, few enough that the answer is in the first screenful.
GOTO_ROWS :: 12

// Open or close the palette. Only in the notes view - the plaintext, the caret and the file list it moves
// between are all there, and the key is left alone everywhere else.
toggle_goto :: proc(app: ^App) {
	if app.goto_open {
		close_goto(app)
		return
	}
	if app.docs == "" {
		bml_status(app, "choose a folder of .bml files first")
		return
	}
	build_goto_index(app)
	if len(app.goto_all) == 0 {
		bml_status(app, "no headings in this folder's .bml files")
		return
	}
	app.goto_open = true
	app.goto_sel = 0
	set_shown(app, "#bml-goto", true)
	set_input(app, "#bml-goto-input", "") // a palette opens empty; the last query is not a state to restore
	draw_goto_list(app)
	if input := find(app, "#bml-goto-input"); input != nil {
		_ = sa.set_focus(input)
	}
	bml_status(app, fmt.tprintf("go to heading - %d in %d files", len(app.goto_all), len(app.bml_names)))
}

// Close it, and hand the keyboard back to the SOURCE rather than to whatever had it before: the palette is
// entered to move the caret, so the thing you want to type into next is the text.
close_goto :: proc(app: ^App, refocus := true) {
	if !app.goto_open {
		return
	}
	app.goto_open = false
	set_shown(app, "#bml-goto", false)
	// `refocus = false` is for a close that happens because the whole VIEW is going away: the source is
	// about to be off screen, and focusing a hidden element is how a window ends up with no focus at all.
	if !refocus {
		return
	}
	if text := find(app, "#bml-text"); text != nil {
		_ = sa.set_focus(text)
	}
}

// Every heading in the folder, the open file's read from the BUFFER. Owned, because the sources are dropped
// as soon as they are parsed: ~1000 headings of two short strings each is tens of KB, against a MB of text
// held for nothing.
build_goto_index :: proc(app: ^App) {
	free_goto_index(app)
	if app.docs == "" {
		return
	}
	found := make([dynamic]outline.Heading, 0, 1024, context.temp_allocator)
	buffer, has_buffer := bml_source(app, context.temp_allocator)
	for name in app.bml_names {
		source := ""
		if has_buffer && name == app.bml_open {
			source = buffer
		} else {
			path, jerr := filepath.join({app.docs, name}, context.temp_allocator)
			if jerr != nil {
				continue
			}
			data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
			if rerr != nil {
				// A file that cannot be read is left out of the list rather than failing the whole
				// palette: the other eighteen chapters are still worth navigating.
				continue
			}
			source = string(data)
		}
		append(&found, ..outline.headings(source, name, context.temp_allocator))
	}
	app.goto_all = outline.clone_headings(found[:], app.allocator)
}

free_goto_index :: proc(app: ^App) {
	if app.goto_all != nil {
		outline.delete_headings(app.goto_all, app.allocator)
		app.goto_all = nil
	}
	if app.goto_rows != nil {
		delete(app.goto_rows, app.allocator)
		app.goto_rows = nil
	}
}

// The list, from whatever is in the input. The rows are KEPT (`goto_rows`) because they are what ENTER and a
// click name: re-ranking on the way to a jump would risk answering a different query than the one on screen.
//
// The strings are borrowed from `goto_all`, which outlives the list, so only the slice is owned here.
draw_goto_list :: proc(app: ^App) {
	query := read_text(app, "#bml-goto-input")
	ranked := outline.rank(app.goto_all, query, app.bml_open, GOTO_ROWS, context.temp_allocator)

	if app.goto_rows != nil {
		delete(app.goto_rows, app.allocator)
	}
	rows := make([]outline.Heading, len(ranked), app.allocator)
	for match, i in ranked {
		rows[i] = match.heading
	}
	app.goto_rows = rows
	app.goto_sel = clamp(app.goto_sel, 0, max(0, len(rows) - 1))

	list := find(app, "#bml-goto-list")
	if list == nil {
		return
	}
	if len(rows) == 0 {
		sa.set_html(list, `<div class="empty">no heading matches</div>`)
		return
	}
	b := strings.builder_make(context.temp_allocator)
	for entry, i in rows {
		// The LEVEL as leading dots, so the shape of the outline survives into a flat list: `2N rebid`
		// under `Responses` under `1C opening` reads as a place rather than as three unrelated names.
		// The FILE on every row, always - the request was to disambiguate duplicate names, and "always" is
		// both simpler than detecting them and more useful, since a corpus-wide list mixes chapters on
		// purpose.
		fmt.sbprintf(
			&b,
			`<div class="%s" data-goto="%d"><span class="depth">%s</span><span class="name">%s</span><span class="where">%s</span></div>`,
			"hit sel" if i == app.goto_sel else "hit",
			i,
			strings.repeat("·", entry.level - 1, context.temp_allocator),
			escape_html(entry.text, context.temp_allocator),
			escape_html(entry.file, context.temp_allocator),
		)
	}
	sa.set_html(list, strings.to_string(b))
}

// Move the highlight, wrapping at both ends: a twelve-row list is a ring, and hitting a wall on a key you
// are holding down is the kind of thing that gets noticed only as "it stopped working".
move_goto :: proc(app: ^App, delta: int) {
	if !app.goto_open || len(app.goto_rows) == 0 {
		return
	}
	count := len(app.goto_rows)
	app.goto_sel = ((app.goto_sel + delta) % count + count) % count
	draw_goto_list(app)
}

/*
Jump to the highlighted heading: the file first if it is another one, then the caret.

The file switch goes through `switch_bml_file`, which is what makes unsaved changes safe - it REFUSES the
first attempt and says so - and the palette stays open when it does, because the answer to "save, or press
enter again" is not to make somebody find their heading a second time.
*/
jump_to_goto :: proc(app: ^App) {
	if !app.goto_open || len(app.goto_rows) == 0 {
		return
	}
	target := app.goto_rows[clamp(app.goto_sel, 0, len(app.goto_rows) - 1)]
	row, file, text := target.row, target.file, target.text
	if file != app.bml_open {
		switch_bml_file(app, file, repreview = false)
		if file != app.bml_open {
			return // refused (unsaved changes); the status line says what to do and the list is still up
		}
	}
	close_goto(app)
	set_caret_row(app, row)
	bml_status(app, fmt.tprintf("%s - line %d - %s", file, row + 1, text))

	// A preview that is UP follows the caret, the same way it follows a file: the section the palette just
	// jumped into is the one worth looking at, and a folded document would otherwise still be open at the
	// section somebody left. Re-rendering is not enough on its own — the fresh document starts at ITS top,
	// so the preview has to be scrolled to the heading as well, or a jump into the middle of a chapter shows
	// the chapter's first page.
	if app.previewed && app.bml_showing {
		if rendered, why := preview_bml(app); !rendered {
			bml_status(app, why)
		}
	}
}

/*
Put the caret on a row of the source, and SCROLL that row into view.

`selectRange` is the plaintext behavior's own method (`selectRange/4` - start row, start column, end row,
end column), reached through the asset because that is where the widget publishes its interface; the same
door `selectionStart` is read through in `caret_row`. An empty selection at the row is what a caret is.

IT DOES NOT SCROLL, measured: jumping to a heading 1700 lines down set the caret there - `selectionStart`
said so, typing went there - and left the view at the top of the file, which reads as the jump having done
nothing. So the scroll is ours, and it is done with `set_scroll_pos` on the widget rather than
`scroll_to_view` on the line, for two reasons the bindings' own notes give: `scroll_to_view` does nothing at
all until the window has been shown and rendered once (so it cannot be tested windowless), and without
`.TO_TOP` it lands on the engine's schedule, so reading the position back can still show the old one.

The line's own box gives the offset, taken with origin `.Container` - the one origin that is measured from
the container's content and does NOT move when the container scrolls. A few lines of lead-in above it,
because a destination pinned to the very top of the pane has no context above it and reads as the file
starting there.
*/
set_caret_row :: proc(app: ^App, row: int) {
	element := find(app, "#bml-text")
	if element == nil {
		return
	}
	asset, aerr := sa.element_asset(element, "plaintext")
	if aerr != nil {
		return
	}
	start_row := sa.value_from(i32(row))
	start_col := sa.value_from(i32(0))
	end_row := sa.value_from(i32(row))
	end_col := sa.value_from(i32(0))
	defer sa.value_clear(&start_row)
	defer sa.value_clear(&start_col)
	defer sa.value_clear(&end_row)
	defer sa.value_clear(&end_col)
	if _, cerr := sa.asset_call(asset, "selectRange", {start_row, start_col, end_row, end_col}); cerr != nil {
		log.warnf("the caret could not be moved to row %d: %v", row, cerr)
	}
	scroll_source_to_row(app, row)
	// The FOCUS is what makes the caret visible and the arrow keys move it; `selectRange` alone leaves the
	// selection set on a widget nobody is typing into.
	_ = sa.set_focus(element)
}

// How many lines of the file to leave above the line jumped to. A heading with nothing above it reads as
// the top of the document; three lines is enough to see that it is not.
GOTO_LEAD_IN :: 3

// Scroll the source pane so `row` is visible, with a few lines above it. The `<text>` children of the
// plaintext are one per line and in order (the same fact `bml_source` reads them back with), so the line
// element is the measurement - no line-height arithmetic, which would be wrong the moment the zoom keys
// were pressed.
scroll_source_to_row :: proc(app: ^App, row: int) {
	element := find(app, "#bml-text")
	if element == nil {
		return
	}
	line, cerr := sa.child(element, sa.Child_Index(row))
	if cerr != nil || line == nil {
		return
	}
	box, lerr := sa.location(line, .Border, .Container)
	if lerr != nil {
		return
	}
	target := box.y - i32(GOTO_LEAD_IN) * max(box.height, 1)
	// The engine clamps an out-of-range scroll rather than refusing it, so the max() is only about not
	// asking for a negative one.
	_ = sa.set_scroll_pos(element, {0, max(target, 0)})
}

/*
The retry behind the preview scroll, and why it exists.

MEASURED, in the window rather than in a test, and this is the whole story: a `<frame>`'s sub-document has
its DOM the instant `loadHtml` returns (the headings are selectable, which is why the lookup test passes)
but it does not have its LAYOUT. Until it does, the document is not taller than its view, so every
scrollable-element candidate clamps a scroll to nothing and reports success having moved nothing -
`update_window` on the host window does not flush it either. Nothing about that is visible except that the
preview stays at the top.

So the scroll is a REQUEST, not a call: it is tried, the numbers say whether it landed, and if it did not it
is asked again on a short timer until it does or the tries run out. `PREVIEW_SCROLL_TRIES` * the interval is
the longest a jump will chase a page - about a third of a second, well under the point where the reader
would start scrolling by hand.

The timer belongs to the FRAME element, not to the window: `.TIMER` is one of the groups that never reaches
a window handler, so the frame carries its own handler (`app.frame_handler`, attached once at startup).
*/
PREVIEW_SCROLL_TIMER :: sa.Timer_Id(7)

/*
THE LIVE PREVIEW: once the pane is up, it follows what is being typed.

A DEBOUNCE, not a render per keystroke. A render is a whole document built and laid out in the frame -
100ms for a chapter shown as one section, 1.02s for the assembled root shown whole (measured; the parse and
the html are 4-18ms of that, the rest is the engine building the sub-document). So the rule is: render when
the typing stops.

THE DELAY SCALES WITH THE DOCUMENT, and the scale is the last render`s OWN cost rather than the file size -
the same 60KB chapter costs 100ms folded and 157ms whole, and the assembled root is 8KB of `#INCLUDE` that
renders to 1.18MB, so bytes on disk are the wrong axis. Four times the last cost, floored at the base and
capped, which leaves a chapter at the base and gives the root a few seconds of quiet.

`WORKBENCH_LIVE_MS` sets the base, and 0 turns it off - the `preview` button then goes back to being the
only thing that renders.

The KEY is what arms it, because there is no route from the document`s own `change` event to this side: the
colorizer takes that event in script, and script cannot call the host. The window handler already sees every
key (it is where CTRL+R and the zoom keys live), and a key that changed nothing is answered by the
fingerprint below rather than by a render.
*/
LIVE_PREVIEW_TIMER :: sa.Timer_Id(8)
LIVE_PREVIEW_BASE :: 600 * time.Millisecond
LIVE_PREVIEW_MAX :: 3 * time.Second

// The base delay, from `WORKBENCH_LIVE_MS` if it is set. Anything unreadable is the default rather than an
// error: a mistyped tuning variable must not stop the application from starting.
live_preview_base :: proc() -> time.Duration {
	text := os.get_env("WORKBENCH_LIVE_MS", context.temp_allocator)
	if text == "" {
		return LIVE_PREVIEW_BASE
	}
	ms, ok := strconv.parse_int(strings.trim_space(text))
	if !ok || ms < 0 {
		log.warnf("WORKBENCH_LIVE_MS=%s is not a number of milliseconds - using the default", text)
		return LIVE_PREVIEW_BASE
	}
	return time.Duration(ms) * time.Millisecond
}

// How long the typing has to stop for. Zero means the live preview is off.
live_preview_delay :: proc(app: ^App) -> time.Duration {
	if app.bml_live_base <= 0 {
		return 0
	}
	delay := app.bml_live_base
	if scaled := app.bml_preview_cost * 4; scaled > delay {
		delay = scaled
	}
	return min(delay, LIVE_PREVIEW_MAX)
}

// A key was pressed in the editor. Restarts the countdown - `set_timer` with the same id REPLACES the
// timer, which is exactly the debounce - and does nothing at all when there is no pane to render into.
arm_live_preview :: proc(app: ^App) {
	delay := live_preview_delay(app)
	if delay <= 0 || !app.previewed || !app.bml_showing {
		return
	}
	frame := find(app, "#bml-page")
	if frame == nil {
		return
	}
	_ = sa.set_timer(frame, delay, LIVE_PREVIEW_TIMER)
}

// The countdown ran out: the typing stopped. Renders the buffer into the pane if it is not the buffer the
// pane is already showing.
//
// Three ways this does nothing, all of them the point: the pane was closed while the timer ran, a render is
// already in flight (`preview_bml` refuses re-entry - it pumps the engine, and the second render would be
// building a document inside the first), and the text is unchanged.
live_preview_tick :: proc(app: ^App) {
	if !app.previewed || !app.bml_showing || current_view(app) != .Editor {
		return
	}
	source, got := bml_source(app, context.temp_allocator)
	if !got || hash.fnv64a(transmute([]u8)source) == app.bml_rendered {
		return
	}
	if ok, why := preview_bml(app); !ok {
		bml_status(app, why)
	}
}
PREVIEW_SCROLL_INTERVAL :: 60 * time.Millisecond
PREVIEW_SCROLL_TRIES :: 6

// Ask for the scroll again shortly. The heading is remembered by TEXT, so a re-render between now and the
// retry changes nothing - the heading is found again in whatever document is there.
want_scroll_again :: proc(app: ^App, text: string) {
	if app.scroll_want != text {
		delete(app.scroll_want, app.allocator)
		app.scroll_want = strings.clone(text, app.allocator)
		app.scroll_tries = 0
	}
	if app.scroll_tries >= PREVIEW_SCROLL_TRIES {
		forget_pending_scroll(app)
		return
	}
	if frame := find(app, "#bml-page"); frame != nil {
		_ = sa.set_timer(frame, PREVIEW_SCROLL_INTERVAL, PREVIEW_SCROLL_TIMER)
	}
}

forget_pending_scroll :: proc(app: ^App) {
	delete(app.scroll_want, app.allocator)
	app.scroll_want = ""
	app.scroll_tries = 0
	if frame := find(app, "#bml-page"); frame != nil {
		_ = sa.stop_timer(frame, PREVIEW_SCROLL_TIMER)
	}
}

// One retry. Called from the frame's own handler, and it is also the whole of that handler's job.
retry_pending_scroll :: proc(app: ^App) {
	if app.scroll_want == "" {
		forget_pending_scroll(app)
		return
	}
	app.scroll_tries += 1
	if app.scroll_tries > PREVIEW_SCROLL_TRIES {
		// Said out loud in EVERY build, not only in a debug one: the bug this replaced was a scroll that
		// quietly did not happen, and "the preview is showing the top of the chapter and nothing says why"
		// is the shape that wasted the time.
		bml_status(app, fmt.tprintf("%s · the preview would not scroll to %s", app.bml_open, app.scroll_want))
		forget_pending_scroll(app)
		return
	}
	// `scroll_preview_to_heading` re-arms the timer itself if this attempt does not land either.
	_ = scroll_preview_to_heading(app, app.scroll_want)
}

/*
The frame's own event handler: the two things that can tell us the framed page is ready.

`.DOCUMENT_COMPLETE` is the RIGHT signal and the primary one - the frame behavior raises it when its
document is finished, which is the moment a scroll can be measured. It is also why this handler is on the
frame rather than on the window: like `.TIMER`, it is delivered to the element's own handlers.

The timer is the fallback, for the case the event has already been and gone by the time a scroll is wanted -
the palette can jump into a document that is ALREADY loaded (a re-render is not always involved), and then
there is no completion event coming.

A handler must not move once attached (the engine keeps its address), which is why it lives in `App`.
*/
on_frame_event :: proc(handler: ^sa.Event_Handler, event: sa.Event) -> bool {
	app := (^App)(handler.user_data)
	if te, ok := sa.timer_event(event); ok && te.id == PREVIEW_SCROLL_TIMER {
		retry_pending_scroll(app)
		// `false` STOPS the timer, which is right: each attempt arms the next one only if it has to, so a
		// scroll that landed leaves no timer running.
		return false
	}
	if te, ok := sa.timer_event(event); ok && te.id == LIVE_PREVIEW_TIMER {
		// The debounce ran out. POSTED rather than rendered here: this handler belongs to the frame whose
		// document the render replaces, and rebuilding it from inside its own event dispatch hangs the window
		// (reported as "not responding" after deleting a selection - the delete armed the timer, the timer
		// rendered, and the render pulled the tree out from under the dispatch). `on_posted` runs it one turn
		// of the pump later, with nothing on the stack.
		//
		// `false` stops the timer, so this is a one-shot that the next keystroke re-arms - a repeating timer
		// would re-render the buffer every delay for as long as the pane stayed open.
		//
		// NOT TESTED, and it cannot be from here: `post_callback` posts to a WINDOW, and the tests run in a
		// windowless view - synthesising this timer event in one SEGFAULTS on the post (measured, and it then
		// hangs the test runner the way every engine crash on a test thread does). A test that drove this path
		// would have to be a program with a real window, like `page_check`.
		sa.post_callback(app.window, LIVE)
		return false
	}
	if be, ok := sa.behavior_event(event); ok && be.code == .DOCUMENT_COMPLETE {
		// The document the scroll was waiting for. Never claimed: this is an observation, and the frame's
		// own behavior has its own use for it.
		if app.scroll_want != "" {
			retry_pending_scroll(app)
		}
		return false
	}
	return false
}

/*
Point the preview at the heading the CARET is under - the preview following the caret, in the pane as well as
in what it renders.

WHY IT IS PART OF EVERY RENDER rather than of the jump: a fresh document starts at its own top, and there are
three ways to arrive at one. The palette jumps (which re-renders), `preview` is pressed AFTER a jump has
already moved the caret, and `fold`/`unfold` re-renders where you are. Scrolling from the jump alone fixed
only the first of those - press `preview` after jumping to the bottom of a chapter and it opened at the
chapter's first page, which is what "not the first time" was.

The heading is the nearest one AT OR ABOVE the caret, taken from the BUFFER - the same counting `preview`
does for its fold, and the same reason: the headings in the buffer and the headings in the rendered page are
in the same order, so no ids or line numbers have to be kept in step. Nothing above the caret means the top
of the document, which is where the document already is.
*/
follow_preview_to_caret :: proc(app: ^App) {
	source, got := bml_source(app, context.temp_allocator)
	if !got {
		return
	}
	here, found := outline.heading_at_or_above(source, caret_row(app))
	if !found {
		return
	}
	_ = scroll_preview_to_heading(app, here.text)
}

/*
Scroll the PREVIEW to the same heading, when there is a preview up.

The rendered page is a document in a `<frame>`, so this is a reach into a sub-document: the frame behavior
publishes it as `document`, and from there it is ordinary DOM.

THE HEADING IS FOUND BY ITS ANCHOR ID, and matching on the TEXT - which is what this did first - cannot work
at all. A heading is BML, so it renders as markup: `* 1!c opening` becomes
`<h1 id="1!c_opening">1<span class="ccolor">&#9827;</span> opening</h1>`, and a heading holding a
cross-reference becomes an `<a>` inside an `<h3>`. Nothing in the rendered document reads back as the string
that was typed, so on this corpus - where a great many headings name a suit - the lookup silently found
nothing and the preview never moved. The `id` is the one thing computed from the SOURCE text
(`bml.normalise_header_id`, made public for exactly this), so it is the mapping between the buffer and the
page. A CSS selector is still not used - the ids here start with a digit (`#1C--1D` is not a valid selector),
so the headings are enumerated and their `id` attributes compared, which needs no escaping.

The text is kept as a FALLBACK for a heading that is plain prose, so a page rendered by something that did
not write ids still scrolls.

Folding does not complicate it: a folded page keeps EVERY heading (that is what the outline is), so the
heading being jumped to is in the document either way - open if it is the caret's section, an outline entry
if it is not.

TWO THINGS MADE THE FIRST VERSION OF THIS SCROLL UNRELIABLE, and both were reported as "it works sometimes":

  1. `loadHtml` puts the DOM there synchronously - `select_all` finds the headings immediately - but the
     document has not been LAID OUT yet, and the first load into a frame is the case with no previous layout
     to fall back on. `scroll_to_view` needs layout, so on a freshly opened document it moved nothing at all;
     on later renders the frame was already laid out and it worked, which is exactly the "only the first
     time" shape. `update_window` forces the pending layout and paint before anything here measures.
  2. A heading near the END of a long page could not be reached even once layout existed, because a scroll is
     CLAMPED to the content height: measure too early and the engine has a smaller document than the real
     one, so the scroll stops short. Same fix, plus the clamp is done here against the scroller's own
     `scroll_info` rather than left to the engine, so a short landing is visible in the numbers.

So this scrolls by MEASUREMENT (`set_scroll_pos`) rather than by `scroll_to_view`: the same choice, for the
same reason, as `scroll_source_to_row` - `set_scroll_pos` has no "must have been rendered" precondition and
lands before it returns.
*/
scroll_preview_to_heading :: proc(app: ^App, text: string) -> (found: bool) {
	element := find(app, "#bml-page")
	if element == nil {
		return false
	}
	asset, aerr := sa.element_asset(element, "frame")
	if aerr != nil {
		return false
	}
	document, derr := sa.asset_get(asset, "document")
	defer sa.value_clear(&document)
	if derr != nil {
		return false
	}
	root, rerr := sa.element_from_value(&document)
	if rerr != nil {
		return false
	}
	// The pending layout, BEFORE anything is measured: see (1) and (2) above.
	sa.update_window(app.window)

	headings, herr := sa.select_all(root, "h1,h2,h3,h4", context.temp_allocator)
	if herr != nil {
		return false
	}
	wanted_id := bml.normalise_header_id(text, context.temp_allocator)
	for heading in headings {
		if !heading_is(heading, wanted_id, text) {
			continue
		}
		moved, note := scroll_preview_frame(app, root, heading)
		if moved {
			forget_pending_scroll(app)
		} else {
			// NOT a failure yet: a frame's sub-document is laid out on the engine's own schedule, so the
			// first attempt can be measuring a document that is not tall enough to scroll yet (its
			// `content` still equals its `view`, so every candidate clamps to nothing). Ask again shortly.
			want_scroll_again(app, text)
		}
		_ = note
		when ODIN_DEBUG {
			// The numbers, in the transcript, because this is the one part of the jump no test can watch:
			// a windowless view must not reach into a DISPLAYED frame, and a hidden frame has no layout to
			// scroll. So the real window is the only witness, and it says what it measured.
			transcribe_local(app, fmt.tprintf("preview scroll: %q %s", text, note))
			// And in the editor's own status line, because the transcript lives on the DEALS view and this
			// is being read while looking at the notes.
			bml_status(app, fmt.tprintf("scroll %s", note))
		}
		return true
	}
	return false
}

// Is this rendered heading the source heading `text` (whose anchor id is `wanted_id`)? The id first, since
// that is the reliable half; the text second, for a page with no ids in it.
heading_is :: proc(heading: sa.Element, wanted_id: string, text: string) -> bool {
	if id, err := sa.attribute(heading, "id", context.temp_allocator); err == nil && id != "" {
		if id == wanted_id {
			return true
		}
	}
	content, terr := sa.text(heading, context.temp_allocator)
	return terr == nil && strings.trim_space(content) == text
}

/*
Scroll the framed page to `target`, trying each thing that could be the scroller until one MOVES.

WHY A LADDER RATHER THAN A CHOICE: which element scrolls a document is not something the host can know from
the outside. The obvious candidates disagree - `<html>` is the usual scroller, but the preview's own
`body { size: * }` makes the body a full-height box, a page could put its scroll on a column of its own, and
a `<frame>`'s own element is a third possibility. And every wrong guess FAILS SILENTLY in the same way: the
scroll is clamped to `content - view`, which for a non-scrolling element is zero, so `set_scroll_pos`
succeeds and nothing moves. That is exactly the bug this replaced - a scroll that "worked sometimes".

So each candidate is asked to move and then CHECKED, and the first one whose scroll position actually
changed wins. `note` says which, with the numbers, for the debug transcript.
*/
Scroll_Candidate :: struct {
	name:    string,
	element: sa.Element,
}

scroll_preview_frame :: proc(app: ^App, root: sa.Element, target: sa.Element) -> (moved: bool, note: string) {
	body, _ := sa.select_first(root, "body")
	frame := find(app, "#bml-page")

	candidates := []Scroll_Candidate {
		{"scrollable-ancestor", scroller_of(target, root)},
		{"body", body},
		{"root", root},
		{"frame", frame},
	}

	reasons := strings.builder_make(context.temp_allocator)
	for candidate in candidates {
		if candidate.element == nil {
			continue
		}
		before, ierr := sa.scroll_info(candidate.element)
		if ierr != nil {
			fmt.sbprintf(&reasons, " %s=unreadable", candidate.name)
			continue
		}
		wanted, ok := scroll_target_for(candidate.element, target, before)
		if !ok {
			fmt.sbprintf(&reasons, " %s=unmeasurable", candidate.name)
			continue
		}
		if wanted == before.pos.y && wanted > 0 {
			// Already there - a re-render that landed on the same heading, which is not a failure.
			return true, fmt.tprintf("already at %d via %s", wanted, candidate.name)
		}
		_ = sa.set_scroll_pos(candidate.element, {0, wanted})
		after, aerr := sa.scroll_info(candidate.element)
		if aerr == nil && after.pos.y != before.pos.y {
			return true, fmt.tprintf(
				"%d -> %d via %s (content %d, view %d)",
				before.pos.y,
				after.pos.y,
				candidate.name,
				before.content.y,
				before.view.height,
			)
		}
		fmt.sbprintf(
			&reasons,
			" %s=stuck(want %d, content %d, view %d)",
			candidate.name,
			wanted,
			before.content.y,
			before.view.height,
		)
	}
	// NOTHING TO SCROLL is not the same as NOT SCROLLED, and telling them apart is what keeps the give-up
	// message honest: a chapter shorter than the pane has no scrollbar, and the heading is on screen
	// already. Only a target that is genuinely off view is a failure worth retrying and then reporting.
	if info, ierr := sa.scroll_info(root); ierr == nil {
		if here, herr := sa.location(target, .Border, .Root); herr == nil {
			if here.y >= 0 && here.y + here.height <= info.view.height {
				return true, fmt.tprintf("already in view at %d (page does not scroll)", here.y)
			}
		}
	}
	return false, fmt.tprintf("nothing scrolled:%s", strings.to_string(reasons))
}

/*
Where `scroller` has to be scrolled to for `target` to be at the top of it.

`.Root` positions are what the viewport currently shows, so adding the scroller's own scroll position turns
one into a content-space offset. The clamp is ours rather than the engine's - the engine clamps silently, and
a silent clamp is how a heading near the bottom of a page ends up "not scrolled to" with every call
reporting success.

`ok = false` for an element that cannot scroll at all (its content fits its view), which is how the ladder
above tells a wrong candidate from a right one.
*/
scroll_target_for :: proc(scroller: sa.Element, target: sa.Element, info: sa.Scroll_Info) -> (wanted: i32, ok: bool) {
	limit := info.content.y - info.view.height
	if limit <= 0 {
		return 0, false
	}
	here, herr := sa.location(target, .Border, .Root)
	box, berr := sa.location(scroller, .Border, .Root)
	if herr != nil || berr != nil {
		return 0, false
	}
	// A line of air above the heading, for the same reason the source pane gets three: a heading flush with
	// the top edge reads as the start of the document.
	return clamp(here.y - box.y + info.pos.y - max(here.height / 2, 4), 0, limit), true
}

// Which element actually scrolls `element`: the nearest ancestor whose content is taller than its view, or
// the document root if nothing in between is scrollable. The preview's pages put the scroll on the root, but
// a page that wrapped its content in a scrolling column would otherwise leave this scrolling nothing.
scroller_of :: proc(element: sa.Element, root: sa.Element) -> sa.Element {
	node := sa.parent(element) or_else nil
	for _ in 0 ..< 8 {
		if node == nil {
			break
		}
		if info, err := sa.scroll_info(node); err == nil && info.content.y > info.view.height {
			return node
		}
		if node == root {
			break
		}
		node = sa.parent(node) or_else nil
	}
	return root
}

/*
The palette's keys. Reported like `zoom_key` so the caller can leave everything else alone.

INTERCEPTED AT THE SINKING PHASE by the caller, which is the whole trick: the query is typed into an
`<input>`, and its intrinsic edit behavior sees ENTER, ESCAPE and the arrows first. A bubbling handler would
be told the event was HANDLED (or not told at all), so the palette would swallow no key and answer none.
Everything that is not one of these five keys is left to fall through and be typed.
*/
goto_key :: proc(app: ^App, key_code: u32, modifiers: sciter.Keyboard_States) -> bool {
	if sciter.KEYBOARD_STATE_CONTROL & modifiers != {} {
		// CTRL+R, the way in and the way out. Only in the notes view: everywhere else the key is nobody's.
		if sciter.Sc_Kb_Codes(key_code) == .R && current_view(app) == .Editor {
			toggle_goto(app)
			return true
		}
		return false
	}
	if !app.goto_open {
		return false
	}
	#partial switch sciter.Sc_Kb_Codes(key_code) {
	case .ESCAPE:
		close_goto(app)
		bml_status(app, app.bml_open)
		return true
	case .DOWN:
		move_goto(app, 1)
		return true
	case .UP:
		move_goto(app, -1)
		return true
	case .ENTER, .KP_ENTER:
		jump_to_goto(app)
		return true
	}
	return false
}

// ---------------------------------------------------------------------------------------------------
// The geometry dump (debug builds only)
//
// A windowless probe can assert a page's layout, and `just page-check` does — but it cannot show what a
// REAL window does: hover, a slider drag, the frame's own scrollbars, a window the user resized. Nearly
// every layout bug in the hosted card page was found by someone LOOKING at the window and none of them by a
// test, so this is the way the live window's numbers get out of it: press `dump` in the page bar and the
// framed document's boxes and the handful of computed styles this engine reads differently land in the
// transcript (and on stderr, where a debug build has a console).
//
// The measuring is done IN the sub-document, in one `eval_element`, because that is where
// `getComputedStyle` and `getBoundingClientRect` are — the host's `location` gives boxes but no styles, and
// a round trip per property would be a hundred crossings.

// One script, one string back. Written with no backticks so it can live in an Odin raw string, and with no
// arrow functions or `let` so it reads the same as the card page's own (ES5) script.
@(private = "file")
PAGE_DUMP_JS :: `(function () {
	var out = [];
	function pad(s) { while (s.length < 22) { s += ' '; } return s; }
	function box(el) {
		var r = el.getBoundingClientRect();
		return Math.round(r.left) + ',' + Math.round(r.top) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height);
	}
	function styles(el) {
		var s = getComputedStyle(el);
		var props = ['display', 'flow', 'position', 'fontSize', 'lineHeight', 'width', 'maxHeight', 'overflow'];
		var kept = [];
		for (var i = 0; i < props.length; i++) {
			var v = s[props[i]];
			if (v !== undefined && v !== '') { kept.push(props[i] + '=' + v); }
		}
		return kept.join(' ');
	}
	out.push('view ' + document.documentElement.clientWidth + 'x' + document.documentElement.clientHeight +
		'   document ' + document.body.scrollWidth + 'x' + document.body.scrollHeight +
		'   scrollTop ' + document.body.scrollTop);
	var track = document.getElementById('nc-track');
	if (track) {
		out.push('track margin-left=' + (track.style.marginLeft || '-') +
			' transform=' + (track.style.transform || '-') +
			' offsetLeft=' + track.offsetLeft + ' offsetWidth=' + track.offsetWidth);
	}
	var idx = document.getElementById('nc-idx'), total = document.getElementById('nc-total');
	if (idx && total) { out.push('board ' + idx.textContent + ' of ' + total.textContent); }
	var slides = document.querySelectorAll('.slide');
	if (slides.length) {
		var parts = [];
		for (var j = 0; j < slides.length; j++) {
			parts.push(j + ':' + slides[j].offsetLeft + '+' + slides[j].offsetWidth +
				(slides[j].classList.contains('active') ? '*' : ''));
		}
		out.push('slides ' + parts.join(' '));
	}
	var sel = ['.toolbar', '.page-title', '.viewport', '.slide.active', '.compass', '.compass .mid', '.stats',
		'.seat-n', '.seat-w', '.seat-w .lbl', '.seat-e', '.table', '.par', '.combo', '.cca-panel', '.cca-head',
		'.cca-sim', '.cca-strain', '.cca-lead', '.cca-side', '.cca-opp', '.opp-grid', '.ct', '.cca-foot',
		'.cca-slider', '#nc-cca-target', '#nc-cca-target-val', '.cca-help', '.cca-help-card', '.cca-tip'];
	for (var k = 0; k < sel.length; k++) {
		var el = document.querySelector(sel[k]);
		if (!el) { out.push(pad(sel[k]) + 'MISSING'); continue; }
		out.push(pad(sel[k]) + box(el) + (el.hasAttribute('hidden') ? ' [hidden]' : '') + '   ' + styles(el));
	}
	// A backslash-n inside an Odin RAW string is two characters, which is exactly what JS wants here.
	return out.join('\n');
})()`

// Measure the hosted page and put the result in the transcript. Says why rather than staying silent when
// there is nothing to measure — a dump that reports nothing is indistinguishable from a broken button.
dump_page :: proc(app: ^App) {
	asset, has_asset := page_frame_asset(app)
	if !has_asset {
		transcribe_local(app, "dump: the page frame is not there")
		return
	}
	document, derr := sa.asset_get(asset, "document")
	defer sa.value_clear(&document)
	if derr != nil {
		transcribe_local(app, fmt.tprintf("dump: the frame has no document yet (%v)", derr))
		return
	}
	root, rerr := sa.element_from_value(&document)
	if rerr != nil {
		transcribe_local(app, fmt.tprintf("dump: the frame's document is not an element (%v)", rerr))
		return
	}

	result, err := sa.eval_element(root, PAGE_DUMP_JS)
	defer sa.value_clear(&result)
	if err != nil {
		transcribe_local(app, fmt.tprintf("dump: could not run the measuring script (%v)", err))
		return
	}
	text, terr := sa.value_to_string(&result, context.temp_allocator)
	if terr != nil {
		transcribe_local(app, fmt.tprintf("dump: unreadable result (%v)", terr))
		return
	}
	// `value_is_error` is how a script error arrives — the call itself still answers nil (odin-sciter's
	// `eval` documents this), so checking only `err` would report a stack trace as a successful dump.
	if sa.value_is_error(&result) {
		transcribe_local(app, fmt.tprintf("dump: the measuring script failed: %s", text))
		return
	}

	// `text`, not `read_text`: the bar's title is a `<span>` and a span has no VALUE — reading it that way
	// comes back empty, which is how this line first shipped an unnamed dump.
	title := ""
	if el := find(app, "#page-title"); el != nil {
		title, _ = sa.text(el, context.temp_allocator)
	}
	transcribe_local(app, fmt.tprintf("---- page dump: %s ----", title))
	transcribe_local(app, text)
	transcribe_local(app, "---- end of dump ----")
	fmt.eprintln(text) // a debug build has a console; this is the copy-pasteable one
}

// Show a text output — pretty, line, pbn — in the frame, as text. The frame is a document viewer and this
// is the smallest document that shows a file: one `<plaintext>`, the engine's own code-editor widget, which
// brings its own scrolling and selection. Wrapped rather than loaded raw because `loadFile` on a `.txt`
// would have the engine guess at markup in a file full of `<` and `&`.
show_text_file :: proc(app: ^App, path: string) -> bool {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return false
	}
	// A generated text file is tens of KB; the cap is here so a mis-click on something enormous cannot wedge
	// the window, and it says what it did rather than truncating in silence.
	TEXT_CAP :: 4 * 1024 * 1024
	body := string(data)
	note := ""
	if len(body) > TEXT_CAP {
		body = body[:TEXT_CAP]
		note = fmt.tprintf(
			"<div class=\"note\">showing the first %d KB of %d KB</div>",
			TEXT_CAP / 1024,
			len(data) / 1024,
		)
	}

	document := fmt.tprintf(
		`<html><head><meta charset="utf-8"><style>
			html { background: #11111b; color: #cdd6f4; font-family: monospace; font-size: 14px; }
			body { margin: 0; size: *; flow: vertical; }
			.note { padding: 0.4em 0.6em; color: #f9e2af; }
			plaintext { size: *; padding: 0.4em 0.6em; overflow: scroll-indicator; white-space: pre; }
		</style></head><body>%s<plaintext>%s</plaintext></body></html>`,
		note,
		escape_html(body, context.temp_allocator),
	)
	return show_page_html(app, document, path)
}

// Hand a file to whatever the desktop opens it with. The same call the About panel's link uses; a path
// works where a URL does because this is the shell's "open" verb, not a browser API.
open_in_browser :: proc(path: string) {
	when ODIN_OS == .Windows {
		win.ShellExecuteW(nil, win.utf8_to_wstring("open"), win.utf8_to_wstring(path), nil, nil, win.SW_SHOWNORMAL)
	}
}

// The frame behavior's interface. `element_asset` is nil until the element's style is RESOLVED, so a
// freshly `set_html`ed frame needs a pump first — not a concern here (the frame is in the document from
// the start), but it is why this is a lookup rather than something cached at startup.
page_frame_asset :: proc(app: ^App) -> (asset: ^sciter.Som_Asset_T, ok: bool) {
	element := find(app, "#page")
	if element == nil {
		return nil, false
	}
	found, err := sa.element_asset(element, "frame")
	return found, err == nil
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
	return fallback, fmt.tprintf(
		"%s is not reachable (no such drive or folder above it) — using %s",
		candidate,
		fallback,
	)
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

/*
The window's own zoom: CTRL+wheel, CTRL+plus / CTRL+minus, CTRL+0 back to normal.

The scale itself is CSS `zoom` on the root element, applied by the document's script — which is where it has
to live, because the WHEEL is a script event and a wheel's delta reaches no host handler at all
(`MOUSE_PARAMS` has no delta field). So the split is: the script owns the property and the clamp, this side
owns the keyboard and the status line, and both go through the same two functions. `zoom_factor` reads it
back rather than remembering it, so the two halves cannot disagree.

`zoom` is a LAYOUT property in this engine, not a paint one — a 57×31 button measures 86×46 at 1.5 and
exactly 57×31 again when it is removed (measured) — which is why one property scales the whole shell,
fixed pixel widths and all.
*/
zoom_step :: proc(app: ^App, direction: int) -> f64 {
	script := fmt.tprintf("wbZoomStep(%d)", direction)
	result, err := sa.eval(app.window, script)
	defer sa.value_clear(&result)
	if err != nil {
		log.warnf("the zoom did not change: %v", err)
		return 1
	}
	factor, ferr := sa.value_to_f64(&result)
	if ferr != nil {
		return 1
	}
	return factor
}

/*
The zoom, remembered across sessions - the one preference that is the WINDOW's rather than a file's.

Written on every keyboard step; the wheel is not caught here, so a wheel-only zoom is remembered the next time
a key is pressed. That is a deliberate limit rather than a plan: catching the wheel would mean the document
telling the host what it did, and a scale that survives most of the time is worth more than that machinery.
*/
ZOOM_PREF :: "zoom"

remember_zoom :: proc(app: ^App, factor: f64) {
	if app.prefs.values == nil {
		return
	}
	prefs.set(&app.prefs, ZOOM_PREF, fmt.tprintf("%.2f", factor))
	if app.prefs_path != "" {
		_ = prefs.save(&app.prefs, app.prefs_path)
	}
}

// Put back what was remembered, once the document is up (the scale lives on its root element).
restore_zoom :: proc(app: ^App) {
	remembered, found := prefs.get(&app.prefs, ZOOM_PREF)
	if !found {
		return
	}
	factor, ok := strconv.parse_f64(remembered)
	if !ok || factor <= 0 {
		return
	}
	script := fmt.tprintf("wbSetZoom(%f)", factor)
	result, err := sa.eval(app.window, script)
	sa.value_clear(&result)
	if err != nil {
		log.warnf("the remembered zoom (%v) was not applied: %v", remembered, err)
	}
}

// The scale as the document has it. Read rather than cached: the wheel changes it without telling this side.
zoom_factor :: proc(app: ^App) -> f64 {
	result, err := sa.eval(app.window, "wbZoom()")
	defer sa.value_clear(&result)
	if err != nil {
		return 1
	}
	factor, ferr := sa.value_to_f64(&result)
	return ferr == nil ? factor : 1
}

/*
CTRL + a key that means zoom. Reports whether it was one, so the caller can leave everything else alone.

The key codes are the ENGINE's (`sciter.Sc_Kb_Codes`), not the platform's — the engine translates, so a
Windows `VK_OEM_MINUS` arrives as `.MINUS`. Both the main row and the numpad are accepted, and `.EQUAL` is
here because CTRL+`+` on most layouts is CTRL+SHIFT+`=` and the shift is not worth insisting on.
*/
zoom_key :: proc(app: ^App, key_code: u32, modifiers: sciter.Keyboard_States) -> bool {
	if sciter.KEYBOARD_STATE_CONTROL & modifiers == {} {
		return false
	}
	direction := 0
	// `#partial`: this is three keys out of a hundred and the rest are somebody else's business.
	#partial switch sciter.Sc_Kb_Codes(key_code) {
	case .EQUAL, .KP_ADD:
		direction = 1
	case .MINUS, .KP_SUBTRACT:
		direction = -1
	case .NUM_0, .KP_0:
		direction = 0
	case:
		return false
	}
	factor := zoom_step(app, direction)
	set_status(app, fmt.tprintf("zoom %d%%", int(factor * 100 + 0.5)))
	remember_zoom(app, factor)
	return true
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

// Show a two-state control as on or off. The same `class` route the tab strip takes, and for the same
// reason: the model is the truth and the attribute is the projection, so nothing here has to ask the button
// what state it is in.
mark_toggle :: proc(app: ^App, selector: string, on: bool) {
	element := find(app, selector)
	if element == nil {
		return
	}
	sa.set_attribute(element, "class", "ghost sel" if on else "ghost")
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
// ---------------------------------------------------------------------------------------------------
// Drag and drop
//
// Drop a screenshot of a hand diagram on the window and it is read, analysed and drawn — the shortest
// path there is from "I saw a hand online" to the card page, and the one thing a desktop app can do that
// the command line cannot.
//
// The protocol is the engine's EXCHANGE group and it has one trap: **both `.WILL_ACCEPT_DROP` and `.DRAG`
// have to be consumed**, or the engine tells the drag source it is not interested and no `.DROP` ever
// arrives (odin-sciter's `examples/drag_and_drop.odin` measured that; `sciter-x-behavior.h` documents only
// the first). Each event arrives twice, sinking then bubbling, so acting on one phase is what keeps a drop
// from counting twice.
//
// The payload was measured on Windows 11, engine 6.0.4.9, dragging a file out of Explorer:
//
//	data = MAP { "file": ARRAY [ "file:///C:/Users/.../hand.png" ] }
//
// — a URL, percent-encoded, not a path. On Linux the same map came back EMPTY (the same measurement, in
// odin-sciter's example), so this feature is Windows-shaped: `drop_file_path` simply reports "nothing to
// take" there and the status line says so, rather than the window silently swallowing drops.

// The dropped file, as a path. Splitting this out of the event is what makes it testable — a real system
// drag cannot be staged from a test, but the map the engine hands over can be built by hand.
drop_file_path :: proc(data: ^sa.Value, allocator := context.allocator) -> (path: string, ok: bool) {
	files, err := sa.value_get(data, "file")
	if err != nil {
		return "", false
	}
	defer sa.value_clear(&files)

	first := files
	if kind, _ := sa.value_type(&files); kind == .ARRAY {
		element, at_err := sa.value_at(&files, 0)
		if at_err != nil {
			return "", false
		}
		defer sa.value_clear(&element)
		return file_url_to_path(sa.value_to_string(&element, context.temp_allocator) or_else "", allocator)
	}
	return file_url_to_path(sa.value_to_string(&first, context.temp_allocator) or_else "", allocator)
}

// `file:///C:/a%20deal.png` -> `C:/a deal.png`. The engine hands over a URL, and a screenshot in a folder
// with a space in its name is not an edge case — the percent-decode is the whole point of this proc.
file_url_to_path :: proc(url: string, allocator := context.allocator) -> (path: string, ok: bool) {
	rest := url
	if strings.has_prefix(rest, "file:///") {
		rest = rest[len("file:///"):]
		// A UNC url (`file://server/share`) keeps its leading slashes; a drive-letter one does not.
		when ODIN_OS != .Windows {
			rest = url[len("file://"):]
		}
	} else if strings.has_prefix(rest, "file://") {
		rest = rest[len("file://"):]
	}
	if rest == "" {
		return "", false
	}

	b := strings.builder_make(allocator)
	for i := 0; i < len(rest); i += 1 {
		if rest[i] == '%' && i + 2 < len(rest) {
			if n, parsed := strconv.parse_uint(rest[i + 1:i + 3], 16); parsed {
				strings.write_byte(&b, u8(n))
				i += 2
				continue
			}
		}
		strings.write_byte(&b, rest[i])
	}
	return strings.to_string(b), true
}

// What a dropped file MEANS. By extension, which is all a drop carries — and everything the window already
// knows how to do gets a drop for free: an image is read, a deal file is analysed, a page is shown.
Drop_Action :: enum {
	Unknown,
	Read_Image, // a hand diagram: hand-ocr, then analyse
	Deal_File, // .pbn / .lin / .txt: analyse it directly
	Page, // .html: show it in the frame (or hand a handviewer page to the browser)
}

drop_action :: proc(path: string) -> Drop_Action {
	lower := strings.to_lower(path, context.temp_allocator)
	switch filepath.ext(lower) {
	case ".png", ".jpg", ".jpeg", ".bmp", ".webp", ".gif", ".tif", ".tiff":
		return .Read_Image
	case ".pbn", ".lin", ".txt":
		return .Deal_File
	case ".html", ".htm":
		return .Page
	}
	return .Unknown
}

// A drop that has landed. Engine-thread only (it touches the DOM and starts jobs).
handle_drop :: proc(app: ^App, data: ^sa.Value) {
	path, ok := drop_file_path(data, context.temp_allocator)
	if !ok {
		set_status(app, "that drop carried no file the window could read")
		return
	}
	if app.running {
		set_status(app, fmt.tprintf("busy — %s dropped, try again when this run finishes", filepath.base(path)))
		return
	}

	switch drop_action(path) {
	case .Read_Image:
		job, err := ocr_job(app, path)
		if err != "" {
			set_status(app, err)
			return
		}
		start_job(app, job, fmt.tprintf("reading %s…", filepath.base(path)))

	case .Deal_File:
		// `--file` rather than the text: the parser scans the whole file for a `[Deal]` tag, so a multi-board
		// PBN arrives as the carousel it is instead of as a textarea full of tags.
		argv, flag_err := analyse_flags(app)
		if flag_err != "" {
			set_status(app, flag_err)
			return
		}
		append(&argv, "--file", path)
		start_job(
			app,
			Job{kind = .Analyse, argv = clone_strings(argv[:], app.allocator), want_page = read_bool(app, "#as-page")},
			fmt.tprintf("analysing %s…", filepath.base(path)),
		)

	case .Page:
		switch file_kind(path) {
		case .Cards:
			if !show_page_file(app, path) {
				set_status(app, "that page could not be loaded into the frame")
			}
		case .Handviewer:
			open_in_browser(path)
			set_status(app, fmt.tprintf("handviewer pages embed bridgebase.com — opened %s in your browser", path))
		case .Text:
			if !show_text_file(app, path) {
				set_status(app, fmt.tprintf("could not read %s", path))
			}
		}

	case .Unknown:
		set_status(
			app,
			fmt.tprintf(
				"%s is not something this window reads — drop a hand-diagram image, a .pbn/.lin, or a page",
				filepath.base(path),
			),
		)
	}
}

on_event :: proc(handler: ^sa.Event_Handler, event: sa.Event) -> bool {
	app := (^App)(handler.user_data)

	// A drop, from anywhere on the window. Sinking only: every one of these arrives twice (see the section
	// above), and a `.DROP` taken in both phases starts the job twice.
	if xe, is_exchange := sa.exchange_event(event); is_exchange {
		if xe.phase != .Sinking {
			return false
		}
		switch xe.code {
		case .WILL_ACCEPT_DROP, .DRAG:
			// BOTH, or the drag source is told no and the drop never lands. Not a redundant pair.
			return true
		case .DRAG_ENTER:
			set_status(app, "drop a hand-diagram image, a .pbn/.lin deal, or a page")
			return false
		case .DROP:
			handle_drop(app, xe.data)
			return true
		case .DRAG_LEAVE, .DRAG_CANCEL, .PASTE, .DRAG_REQUEST:
		// not ours
		}
		return false
	}

	// CTRL+plus / CTRL+minus / CTRL+0. Claimed when it was a zoom key so the keystroke does not also reach
	// whatever has the focus; everything else is left alone, including every key the editor needs.
	if ke, ok := sa.key_event(event); ok {
		// The palette's keys are taken on the way DOWN, before the query input's own edit behavior sees
		// ENTER, ESCAPE or an arrow (see `goto_key`). Everything else falls through and is typed.
		if ke.code == .DOWN && ke.phase == .Sinking && goto_key(app, ke.key_code, ke.modifiers) {
			return true
		}
		if ke.code == .DOWN && ke.phase == .Bubbling && zoom_key(app, ke.key_code, ke.modifiers) {
			return true
		}
		// Every other key in the editor restarts the live preview`s countdown. A key rather than an edit
		// because an edit has no route to this side (see `arm_live_preview`), and it costs nothing to be
		// wrong: a key that changed no text is answered by the fingerprint when the timer fires.
		if ke.code == .DOWN && ke.phase == .Bubbling && current_view(app) == .Editor {
			arm_live_preview(app)
		}
		return false
	}

	// The hint bar, from whatever the pointer or the keyboard is on. Reading it from the DOM is right: the
	// text is authored in the document beside the control it describes, so there is no table here to fall
	// out of step with the markup. Never claims the event — hovering must not stop being a hover.
	if me, ok := sa.mouse_event(event); ok && me.phase == .Bubbling {
		switch me.code {
		case .MOUSE_ENTER:
			show_hint(app, hint_for(me.target))
		case .MOUSE_LEAVE:
			show_hint(app, "")
		case .MOUSE_MOVE,
		     .MOUSE_UP,
		     .MOUSE_DOWN,
		     .MOUSE_DCLICK,
		     .MOUSE_WHEEL,
		     .MOUSE_TICK,
		     .MOUSE_IDLE,
		     .DROP,
		     .DRAG_ENTER,
		     .DRAG_LEAVE,
		     .DRAG_REQUEST,
		     .MOUSE_TCLICK,
		     .MOUSE_DRAG_REQUEST,
		     .MOUSE_CLICK,
		     .DRAGGING,
		     .MOUSE_HIT_TEST:
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
	// The palette's query, per character: the edit behavior raises `.VALUE_CHANGED` and the list is a
	// projection of what is in the box, so this is the only place the ranking is re-run.
	if be.code == .VALUE_CHANGED {
		if id, _ := sa.attribute(be.target, "id", context.temp_allocator); id == "bml-goto-input" {
			app.goto_sel = 0 // a new query is a new list; keeping the old row would highlight a stranger
			draw_goto_list(app)
			return true
		}
		return false
	}

	// A `<button>` raises `.BUTTON_CLICK`; an `<a href>` raises `.HYPERLINK_CLICK` instead, and returning
	// true from it is also what stops the engine trying to navigate THIS window to the href.
	if be.code != .BUTTON_CLICK && be.code != .HYPERLINK_CLICK {
		return false
	}

	// A TAB, before the ids: the header is navigation and it is the one control group that names its
	// destination in the document rather than in this switch (see `view_of`). The editor is entered through
	// `show_editor` rather than `show_view` because it has a file to open on the first visit and a corpus
	// that might not be there at all.
	if destination, _ := sa.attribute(be.target, "data-view", context.temp_allocator); destination != "" {
		view, known := view_of(destination)
		if !known {
			return false
		}
		switch view {
		case .Editor:
			show_editor(app)
		case .Panes:
			show_view(app, view)
		case .About:
		// not a tab; About is entered from its own button
		}
		return true
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

	case "help-generate", "help-analyse", "help-bml":
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

	case "view-page":
		// The page for the SCENARIO THAT IS SELECTED, wherever it came from — this run, an earlier batch, or
		// yesterday's. Resolved on the click rather than tracked: the fields it depends on (the scenario, the
		// output directory, the format) are all editable, and a button whose enabled state chases three
		// controls goes stale in a way nobody can see.
		path, kind, found, why := selected_output(app)
		if !found {
			set_status(app, why)
			return true
		}
		switch kind {
		case .Cards:
			if !show_page_file(app, path) {
				set_status(app, "the hand page could not be loaded into the pane")
			}
		case .Handviewer:
			// A handviewer page is an `<iframe>` per deal onto bridgebase.com. Hosting it here means dozens of
			// https requests and a site that then reports javascript as disabled — it wants a browser, so it
			// gets one. Measured, and the reason this is not simply loaded into the frame.
			open_in_browser(path)
			set_status(app, fmt.tprintf("handviewer pages embed bridgebase.com — opened %s in your browser", path))
		case .Text:
			if !show_text_file(app, path) {
				set_status(app, fmt.tprintf("could not read %s", path))
			}
		}
		return true

	case "page-dump":
		// Debug builds only — the button is hidden otherwise (see `main`).
		dump_page(app)
		return true

	case "deal-page":
		// Nothing behind it yet. The button is disabled in the document as well, but that is the look and not
		// the enforcement: `do_click` runs a disabled button`s behavior and the click arrives here all the
		// same, so the model is what refuses.
		if !app.page_ready {
			set_status(app, "no hand page yet — generate or analyse something, or press view page")
			return true
		}
		show_page_pane(app, !page_pane_shown(app))
		return true

	case "deal-wide":
		if !app.page_ready {
			set_status(app, "no hand page yet — generate or analyse something, or press view page")
			return true
		}
		set_pane_wide(app, !pane_is_wide(app))
		return true

	case "deal-list-toggle":
		show_scenario_list(app, !scenario_list_shown(app))
		return true

	case "bml-files-toggle":
		// The sidebar folds away when the source and the preview want the width. Read from the document
		// rather than remembered, like every other shown/hidden thing here.
		set_shown(app, "#bml-files", effective_display_is_hidden(app, "#bml-files"))
		return true

	case "bml-folder":
		choose_bml_folder(app)
		return true

	case "bml-fold":
		// One toggle, lit while the document is folded, and the choice REMEMBERED for this file because it
		// belongs to the document rather than to the session.
		app.bml_scope = app.bml_scope == .Folded ? .Unfolded : .Folded
		app.bml_scope_set = true
		show_scope_buttons(app)
		remember_scope(app)
		if app.bml_showing {
			_, why := preview_bml(app)
			bml_status(app, why)
		} else {
			bml_status(app, app.bml_scope == .Folded ? "folded, next preview" : "unfolded, next preview")
		}
		return true

	case "bml-links":
		app.bml_links = !app.bml_links
		mark_toggle(app, "#bml-links", app.bml_links)
		// Re-render rather than wait: the button was pressed to see the answer, and the parse is ~2ms. Only
		// into a pane that is up, though.
		if app.previewed && app.bml_showing {
			_, why := preview_bml(app)
			bml_status(app, why)
		} else {
			bml_status(app, app.bml_links ? "cross-references will be checked" : "cross-references off")
		}
		return true

	case "bml-preview":
		// A TOGGLE, because the pane is the expensive thing in this window: closing it hands the document back
		// to the engine (tens to hundreds of MB - see `preview/preview.odin`) and gives the source the whole
		// width. The button's own label says which of the two a press does.
		if app.bml_showing {
			close_preview(app)
			bml_status(app, "preview closed")
			return true
		}
		rendered, why := preview_bml(app)
		bml_status(app, why)
		if !rendered {
			log.warnf("the bml preview did not render: %s", why)
		}
		return true

	case "bml-save":
		written, why := save_bml(app)
		bml_status(app, why)
		if !written {
			log.warnf("the bml file was not saved: %s", why)
		}
		return true

	case "about-sciter-link":
		// The EULA's link. Handled here so the click opens the system browser instead of navigating this
		// window (see open_sciter_site).
		open_sciter_site()
		return true
	}

	// A row of the heading palette. Before the file rows: the palette's rows carry `data-goto` and no
	// `data-file`, but the pointer is as good a way to pick one as the keyboard and it must not fall
	// through to a list that happens to be underneath.
	if index, is_goto := row_goto(be.target); is_goto {
		app.goto_sel = index
		jump_to_goto(app)
		return true
	}

	// A file row in the editor's sidebar. Before the scenario rows, because both are `.row` and only the
	// attribute tells them apart.
	if name, is_file := row_file(be.target); is_file {
		switch_bml_file(app, name)
		return true
	}

	// Not a button: a scenario row. The click may land on one of the row's own spans, so walk up looking
	// for the `data-index` the render wrote. (The bindings have no `closest`; `parent` is the primitive.)
	if index, is_row := row_index(be.target); is_row {
		app.selected = index
		draw_scenarios(app)
		note_selected_page(app)
		return true
	}
	return false
}

// The file a clicked row names: itself, or the nearest ancestor carrying `data-file`. Bounded for the same
// reason `row_index` is — a row is one level deep and an unbounded walk would reach the document root on
// every click that is neither.
row_file :: proc(element: sa.Element) -> (name: string, ok: bool) {
	node := element
	for _ in 0 ..< 3 {
		if node == nil {
			break
		}
		if raw, err := sa.attribute(node, "data-file", context.temp_allocator); err == nil && raw != "" {
			return raw, true
		}
		node = sa.parent(node) or_else nil
	}
	return "", false
}

// The palette row a click landed on: itself, or the nearest ancestor carrying `data-goto`. A row is one
// `<span>` deep, so the walk is bounded the same way `row_file`'s is.
row_goto :: proc(element: sa.Element) -> (index: int, ok: bool) {
	node := element
	for _ in 0 ..< 3 {
		if node == nil {
			break
		}
		if raw, err := sa.attribute(node, "data-goto", context.temp_allocator); err == nil && raw != "" {
			return strconv.parse_int(raw)
		}
		node = sa.parent(node) or_else nil
	}
	return 0, false
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

	// The SDK's inspector — a DevTools-style DOM tree, computed styles and script console over a socket —
	// needs THREE things, and the third is the one everybody misses (odin-sciter's examples/inspector.odin
	// says so, having missed it):
	//
	//   1. the window created with `.ENABLE_DEBUG`, which cannot be turned on afterwards;
	//   2. `set_debug_mode`, which is what makes the engine listen;
	//   3. `.SOCKET_IO` in the script features, because the connection is a socket opened by the DOCUMENT's
	//      own runtime. With 1 and 2 but not 3 the inspector sits on "Waiting for a connection with
	//      Sciter's view" forever, which reads as a problem with 1 or 2.
	//
	// All three are `when ODIN_DEBUG` only: this is `just workbench-debug`, and odin-sciter's release
	// checklist (docs/deployment.md) says not to ship either the flag or a blanket feature grant — least of
	// all socket access, which the HOSTED CARD PAGE's script would inherit (features are process-wide).
	// `just inspector` starts the tool; start it first if it does not pick the window up, or press
	// CTRL+SHIFT+I in the window to connect the current view by hand.
	//
	// `.MAIN` is the flag that makes closing the window end the message pump.
	flags: sciter.Sciter_Create_Window_Flags = {.MAIN}
	when ODIN_DEBUG {
		flags |= {.ENABLE_DEBUG}
		if err := sa.set_debug_mode(true); err != nil {
			fmt.eprintln("could not enable debug mode (the inspector will not attach):", err)
		}
		if err := sa.set_script_features({.SOCKET_IO}); err != nil {
			fmt.eprintln("could not grant the script socket access (the inspector will not attach):", err)
		}
	}
	// The GRAPHICS LAYER. `SET_GFX_LAYER` takes no window, so it is set before the window exists and applies
	// to everything after — but read the default before reaching for it: the SDK's own changelog says a GPU
	// backend is ALREADY the default on every platform (Windows: DX12/Vulkan with an OpenGL fallback; Linux:
	// Vulkan; macOS: Metal). So this is not a "turn the GPU on" switch. It is here to FORCE one backend when
	// a driver misbehaves, and `raster` is the way back to software when a GPU path renders nothing:
	//
	//	WORKBENCH_GFX=gpu      just sims workbench     # the best GPU layer for the platform, explicitly
	//	WORKBENCH_GFX=vulkan   just sims workbench
	//	WORKBENCH_GFX=opengl   just sims workbench
	//	WORKBENCH_GFX=raster   just sims workbench     # software Skia, when a GPU layer misbehaves
	//
	// `graphics_caps` is NOT the answer to "which layer am I on": it is a Direct2D-era rating of the machine
	// (0/1/2) and reports `.Software` here on a build whose default is a GPU layer. Nothing in the API reports
	// the active layer, which is worth knowing before chasing it.
	//
	// And what costs the most on this page is not the raster at all — it is layout. The card page's own board
	// parking took a resize step at 48 boards from 124ms to 9ms. Reach for that first and this second.
	choose_graphics_layer()

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

	// The `sciter` media flag the hosted card page's override block is written against. The flag is a
	// property of the WINDOW, so it covers every document loaded into it and every `<frame>` inside them,
	// and it survives a reload — hence before the first load. It is belt and braces rather than the
	// mechanism: measured, this engine matches `@media sciter` whether or not the flag is set (an unknown
	// bare media name matches, where a browser skips an unknown media TYPE). Setting it says what the page
	// meant and keeps working if a later engine gets stricter.
	set_sciter_media_var(window)

	if err := sa.load_html(window, compose_document(context.temp_allocator), "about:blank"); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	// `.MOUSE` and `.FOCUS` are here for the hint bar; without them the clicks still work and the hint bar
	// stays permanently empty, which is a silent failure worth knowing the shape of.
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = app,
	}
	sa.attach_window_handler(window, &app.handler)

	// Drag and drop, on the document ROOT. Not on the window: a window handler never sees the EXCHANGE
	// group (measured — every drop was refused with no event delivered), and the failure looks like the
	// application simply not accepting drops. The root covers the whole document, so anywhere in the window
	// is a drop target, and it goes away with the document when the window closes.
	app.drops = sa.Event_Handler {
		subscription = {.EXCHANGE},
		on_event     = on_event,
		user_data    = app,
	}
	if root := sa.root(window) or_else nil; root != nil {
		sa.attach_handler(root, &app.drops)
	} else {
		fmt.eprintln("could not attach the drop handler: the document has no root")
	}

	// The preview frame's own handler, for its retry TIMER and nothing else: `.TIMER` is one of the groups
	// that never reaches a WINDOW handler, so a timer on the frame has to be listened for on the frame.
	// Attached once, here, rather than when a scroll is wanted — a handler must not move after attaching and
	// re-attaching per jump would be one more thing to get wrong.
	app.frame_handler = sa.Event_Handler {
		subscription = {.TIMER, .BEHAVIOR_EVENT},
		on_event     = on_frame_event,
		user_data    = app,
	}
	if frame := sa.select_first(sa.root(window) or_else nil, "#bml-page") or_else nil; frame != nil {
		sa.attach_handler(frame, &app.frame_handler)
	}

	// Pre-fill the output directory so the field is never a blank the user has to guess at, and so the
	// destination is VISIBLE before a batch rather than inferred afterwards: DEALS_OUTPUT_DIR when set (the
	// justfile exports the same `w:/deals/` default the `gen-all` recipes use), else this process's working
	// directory, spelled absolutely — the exact thing a relative path would have resolved against.
	// How long the typing has to stop before the preview re-renders itself. Read once: it is a tuning knob,
	// not something that changes while the window is open.
	app.bml_live_base = live_preview_base()

	// `WORKBENCH_COLOUR=0` runs without the colorizer. A bisecting switch, not a feature: when something is
	// wrong WHILE TYPING, the two things running behind the keystrokes are the colour pass and the live
	// preview, and each has to be answerable for on its own (`WORKBENCH_LIVE_MS=0` is the other half).
	if strings.trim_space(os.get_env("WORKBENCH_COLOUR", context.temp_allocator)) == "0" {
		result, err := sa.eval(window, "bmlColorEnabled = false")
		sa.value_clear(&result)
		if err != nil {
			log.warnf("could not turn the colorizer off: %v", err)
		} else {
			log.info("WORKBENCH_COLOUR=0: typing will not re-colour the buffer")
		}
	}

	out_dir, out_note := default_out_dir(context.temp_allocator)
	set_input(app, "#outdir", out_dir)

	// The BML editor's corpus, resolved once at startup rather than per visit: it is a property of where
	// this process is running, not of anything the user does in the window. An empty result is not fatal —
	// the generator and the advisor do not need the notes — so the editor button simply reports it.
	// The remembered per-file choices (which is `preview.scope.<file>` and nothing else so far). A file
	// rather than the document's `@storage`: see `prefs/prefs.odin` for why.
	app.prefs_path = prefs.default_path(app.allocator)
	app.prefs = prefs.load(app.prefs_path, app.allocator)

	docs, docs_note := bml_docs_dir(app.allocator)
	app.docs = docs
	app.bml_names = list_bml_files(docs, app.allocator)
	draw_bml_files(app)

	engine := sa.version()
	engine_text := fmt.tprintf("sciter %d.%d.%d.%d", engine[0], engine[1], engine[2], engine[3])
	// Just the scenario count. The engine's version belongs to the About panel (which prints it, along with
	// Odin's), and putting it here too crowded the About button on a narrow window — the two overlapped.
	set_text_at(app, "#engine", fmt.tprintf("%d scenarios", len(app.scenarios)))

	// The About panel's dynamic lines. The static ones — the Sciter attribution above all — are in the
	// document, where they cannot be reworded by a format string.
	set_text_at(
		app,
		"#about-versions",
		fmt.tprintf("%s · %d scenarios · Odin %s", engine_text, len(app.scenarios), ODIN_VERSION),
	)
	// The page-geometry dump is a development affordance: the stylesheet hides it, and only a `-debug` build
	// puts it on screen.
	when ODIN_DEBUG {
		set_shown(app, "#page-dump", true)
	}

	// The remembered scale, now that there is a document for it to apply to.
	restore_zoom(app)
	restore_deals_layout(app)

	draw_scenarios(app)
	// The opening view. Said out loud rather than left implicit: the panes are what the stylesheet shows,
	// but the TAB that says so is marked here, and nothing else would have marked it until the first click.
	show_view(app, .Panes)
	transcribe_local(
		app,
		"Pick a scenario and press generate, or paste a deal below and press analyse. Everything runs in this process.",
	)
	if docs_note != "" {
		transcribe_local(app, docs_note)
	}
	if out_note != "" {
		// Said once, at startup, rather than discovered when a batch fails: the field shows a directory the
		// user did not ask for, and silently substituting one is worse than naming it.
		transcribe_local(app, out_note)
	}

	// `--mem-report [page.html]`: measure and exit, rather than hand the window over. Placed here, after
	// everything the application sets up, so what is measured is the real thing and not a stripped version.
	if mem_report_path, wanted := mem_report_request(); wanted {
		mem_report(app, mem_report_path)
	} else {
		sa.show(window)
		sa.run() // returns when the window closes
	}

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
	delete(app.page)
	for name in app.bml_names {
		delete(name, app.allocator)
	}
	delete(app.bml_names, app.allocator)
	delete(app.bml_open, app.allocator)
	delete(app.docs, app.allocator)
	free_goto_index(app)
	delete(app.scroll_want, app.allocator)
	prefs.destroy(&app.prefs)
	delete(app.prefs_path, app.allocator)
	free(app)
}

// `--mem-report [page.html]` on the command line. The only argument this application takes: everything else
// it does is a control in the window, and a measurement is not.
mem_report_request :: proc() -> (page_path: string, wanted: bool) {
	for arg, i in os.args[1:] {
		if arg != "--mem-report" {
			continue
		}
		rest := os.args[2 + i:]
		if len(rest) > 0 && !strings.has_prefix(rest[0], "-") {
			return rest[0], true
		}
		return "", true
	}
	return "", false
}

/*
`--mem-report [page.html]`: the same walk `just mem-check` does, in a REAL WINDOW, then exit.

Why both: a windowless view paints into a pixel buffer, so `mem-check` can attribute the DOM, the script heap
and the DDS tables but cannot see what the graphics layer commits. This runs the same stages behind a real
window — GPU backend included, whichever `WORKBENCH_GFX` selects — so the difference between the two totals
IS the graphics layer, measured rather than assumed.

The window is shown and closed by the program, in a couple of seconds, and nothing is written: this is a
measurement, not a mode of the application.
*/
mem_report :: proc(app: ^App, page_path: string) {
	report: perf.Report
	perf.report_begin(&report, "stage (real window)")
	sa.show(app.window)
	spin(20)
	perf.mark(&report, "window shown, shell document up")

	path := page_path
	if path == "" {
		// The same resolution "view page" uses, so the measured page is one the application would show.
		if resolved, kind, found, _ := selected_output(app); found && kind == .Cards {
			path = resolved
		}
	}
	if path == "" {
		fmt.println("(no card page to load: pass one, or generate a scenario first)")
	} else if data, err := os.read_entire_file_from_path(path, context.temp_allocator); err != nil {
		fmt.printfln("(could not read %s: %v)", path, err)
	} else {
		perf.mark(&report, fmt.tprintf("page read (%d KB)", len(data) / 1024))
		if show_page_html(app, string(data), path) {
			spin(30)
			perf.mark(&report, "card page LOADED in the frame")
		}
	}

	if app.docs != "" && len(app.bml_names) > 0 {
		name := "bidding-system.bml"
		if !slice.contains(app.bml_names, name) {
			name = app.bml_names[0]
		}
		if opened, _ := open_bml(app, name); opened {
			spin(10)
			perf.mark(&report, fmt.tprintf("%s in the editor", name))
			if previewed, why := preview_bml(app); previewed {
				spin(30)
				perf.mark(&report, "notes PREVIEWED (a second document)")
			} else {
				fmt.println("(the preview did not render:", why, ")")
			}
		}
	}

	perf.report_end(&report)
	fmt.println("the difference against `just mem-check` is the graphics layer (WORKBENCH_GFX to change it)")
}

// Run the pump for `frames` iterations. `run_once` is the same pump `run` loops over, so this is the real
// thing rather than a simulation of it — layout, script and paint all happen here.
@(private = "file")
spin :: proc(frames: int) {
	for _ in 0 ..< frames {
		if !sa.run_once() {
			return
		}
	}
}

// Apply `WORKBENCH_GFX`, and say both what was asked for and how the engine rates the machine — a frame-rate
// complaint is unanswerable without them. Wrong values are named rather than ignored: a typo in an
// environment variable that silently does nothing is a bad afternoon.
//
// The `caps` number is the Direct2D-era rating (see the caller), not the layer in use, so it is labelled as
// what it is rather than presented as an answer.
choose_graphics_layer :: proc() {
	caps, caps_ok := sa.graphics_caps()
	wanted := strings.to_lower(os.get_env("WORKBENCH_GFX", context.temp_allocator), context.temp_allocator)

	layer: sciter.Gfx_Layer
	switch wanted {
	case "", "auto":
		// The default is already a GPU layer on all three platforms (the SDK's changelog, quoted by the
		// caller), so this line says which lever was NOT pulled rather than implying software rendering.
		fmt.eprintfln(
			"graphics: the engine's own default layer, a GPU one (legacy caps rating: %v, ok=%v)",
			caps,
			caps_ok,
		)
		return
	case "raster":
		layer = .SKIA_RASTER
	case "gpu":
		layer = .SKIA_GPU
	case "vulkan":
		layer = .SKIA_VULKAN
	case "opengl":
		layer = .SKIA_OPENGL
	case:
		fmt.eprintfln("graphics: WORKBENCH_GFX=%q is not one of gpu|vulkan|opengl|raster; using the default", wanted)
		return
	}

	err := sa.set_option(.SET_GFX_LAYER, uintptr(layer))
	fmt.eprintfln(
		"graphics: asked for %v (%v), engine answered %v (system rated %v, ok=%v)",
		layer,
		wanted,
		"accepted" if err == nil else "refused",
		caps,
		caps_ok,
	)
}

// Turn on the `sciter` media flag for a window. Its own document does not use it — `ui/workbench.css` is
// written for this engine from the start — and the card page's override block matches here even without it
// (see the caller); this makes the intent explicit rather than incidental.
set_sciter_media_var :: proc(window: sa.Window) {
	on := sa.value_from(true)
	defer sa.value_clear(&on)
	vars: sa.Value
	defer sa.value_clear(&vars)
	sa.value_set(&vars, "sciter", &on)
	if err := sa.set_media_vars(window, &vars); err != nil {
		// Not fatal: the window works, and only a hosted card page reads the flag.
		fmt.eprintln("could not set the `sciter` media flag; a hosted card page will lay out wrong:", err)
	}
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
	// The same flag `main` sets, and for the same reason: a card page hosted in the frame reads it. Set on
	// every call rather than once with the view, because it is what the frame test is really asserting and
	// a media var that had to be set elsewhere would be a trap for the next test.
	set_sciter_media_var(g_view.window)

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
	free_goto_index(app)
	delete(app.scroll_want, app.allocator)
	delete(app.bml_open, app.allocator) // `open_bml` clones it onto the heap, as `main` frees at exit
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

	for selector in ([]string {
			"#engine",
			"#scenarios",
			"#count",
			"#format",
			"#seed",
			"#outdir",
			"#dd",
			"#fixed",
			"#all",
			"#generate",
			"#cancel",
			"#view-page",
			"#fill",
			"#status",
			"#deal",
			"#sample",
			"#contract",
			"#target",
			"#as-page",
			"#analyse",
			"#clear",
			"#report",
			".panes",
			"#about",
			"#about-panel",
			"#about-close",
			"#about-sciter-link",
			"#about-versions",
			"#about-book",
			"#pageview",
			"#page",
			"#page-title",
			"#page-dump",
			"#tabs",
			`.tab[data-view="panes"]`,
			`.tab[data-view="editor"]`,
		}) {
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
			`.tab[data-view="panes"]`,
			`.tab[data-view="editor"]`,
			"#deal-list-toggle",
			"#deal-page",
			"#deal-wide",
			"#bml-files-toggle",
			"#bml-folder",
			"#bml-fold",
			"#bml-links",
			"#bml-preview",
			"#bml-save",
			"#help-bml",
			"#bml-text",
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
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
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
			{`.tab[data-view="editor"]`, true}, // a tab is a button and paints its own states
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
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
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

// The per-scenario command line must survive a library resetting this thread's temp allocator, because one
// on the far side of `cli.run` does exactly that (`combo.annotate`, Html_Cards path). A temp-allocated `-o`
// path passed the first scenarios of a batch and then arrived as recycled bytes — a filename of NUL
// characters, 45 pages in. The `free_all` below is that reset, in one line.
@(test)
test_a_scenario_command_survives_a_temp_allocator_reset :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#count", "4")
	type_into(&app, "#outdir", PARITY_DIR)
	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	app.job = job
	if len(job.scenarios) != 1 {
		return
	}

	command := scenario_command(&app.job, job.scenarios[0])
	defer command_free(&command)
	expected := command.path

	free_all(context.temp_allocator) // what the far side of cli.run does to this thread

	testing.expect_value(t, command.path, expected)
	testing.expect(t, strings.has_suffix(command.path, ".html"), "the path must still name a page")
	testing.expect(
		t,
		strings.contains(command.path, job.scenarios[0]),
		"and still name the scenario, not recycled bytes",
	)
	// The argv the parser sees is intact too — `-o` last, with that path.
	n := len(command.argv)
	if testing.expect(t, n >= 2, "the argv carries -o <path>") {
		testing.expect_value(t, command.argv[n - 2], "-o")
		testing.expect_value(t, command.argv[n - 1], expected)
	}
	// And norn still accepts it.
	opts, ok, message := cli.parse_args(command.argv[:])
	testing.expectf(t, ok, "norn rejected the composed argv: %s", message)
	testing.expect_value(t, opts.output, expected)
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

// The deal both frame tests use: declarer + dummy, defenders unknown. No `--sample`, so no solver and no
// DDS lifecycle — the page still carries the compass, the combo blob and the whole CCA overlay, which is
// everything the layout has to get right.
FRAME_DEAL :: `[Deal "N:AJ54.AK2.A32.AK3 - KT32.543.654.542 -"]`

// The card page as a string, through the same call the analyse path uses (`analyse.builder_page_sink`, no
// file). Caller owns the page.
@(private = "file")
render_test_page :: proc(t: ^testing.T) -> (page: string, ok: bool) {
	args, perr := analyse.parse_args({FRAME_DEAL}, allow_stdin = false)
	defer analyse.args_free(&args)
	if !testing.expectf(t, perr == "", "the advisor rejected the test deal: %s", perr) {
		return "", false
	}

	report := strings.builder_make()
	defer strings.builder_destroy(&report)
	page_b := strings.builder_make()

	result := analyse.run(analyse.builder_page_sink(&report, &page_b), &args)
	if !testing.expect_value(t, result, analyse.Result.Ok) {
		strings.builder_destroy(&page_b)
		return "", false
	}
	// The diagnostics say what happened, and the page is NOT among them: a page in memory means nothing
	// was written to disk.
	testing.expect(
		t,
		strings.contains(strings.to_string(report), "rendered the card page"),
		"the diagnostics must say the page was rendered",
	)
	return strings.to_string(page_b), true
}

// The page comes back IN MEMORY and carries the desktop overrides. No engine in this one: it is about the
// seam `analyse.builder_page_sink` opened — the page as a string, and nothing written to disk.
@(test)
test_the_analyse_run_hands_back_the_card_page :: proc(t: ^testing.T) {
	defer combo.shutdown() // the page's CCA blob starts combo's pool

	page, ok := render_test_page(t)
	if !ok {
		return
	}
	defer delete(page)

	testing.expect(t, strings.has_prefix(page, "<!DOCTYPE html>"), "the page must be a document")
	testing.expect(t, len(page) > 10_000, "and a whole one")
	testing.expect(t, strings.contains(page, "compass"), "carrying the card page's markup")
	// The two halves of the port that make it show correctly in the frame, pinned so a norn template edit
	// that dropped either is caught HERE rather than as a wrecked-looking window.
	testing.expect(t, strings.contains(page, "@media sciter"), "the page must carry the desktop CSS overrides")
	testing.expect(t, strings.contains(page, "function setHidden"), "and the desktop JS shims")
	// The `@media sciter` block MUST come before the phone media query: this engine treats
	// `@media (max-width: ...)` as a parse error and discards the rest of the stylesheet, so a block after
	// it silently does nothing. Measured — it is how the first cut of the port came to have no effect.
	//
	// Both anchors carry the block's own INDENTATION, because the template's comments name both queries in
	// prose and a bare substring search finds those first (which is how this test first failed).
	sciter_at := strings.index(page, "		@media sciter {")
	phone_at := strings.index(page, "		@media (max-width")
	testing.expect(t, phone_at > 0, "the phone media query must still be there")
	testing.expectf(
		t,
		sciter_at < phone_at,
		"the desktop overrides (at %d) must precede the phone media query (at %d) or the engine drops them",
		sciter_at,
		phone_at,
	)
}

// The frame plumbing, end to end: a document goes in from MEMORY, the engine parses it, its script runs,
// and the host can read the sub-document back out. `frame.document` is the only way in — a selector from
// the outer root does not cross the boundary, and this asserts that too.
//
// WHY A SMALL DOCUMENT AND NOT THE CARD PAGE. Measured on 6.0.4.9: loading the real card page into this
// engine from an Odin TEST-RUNNER thread crashes inside the engine — as a frame document or as the view's
// own document, from memory or from a file, with the media var or without it, and with the page's own
// `<script>` cut out. The same page, the same build flags and the same calls are fine on a program's main
// thread, which is where the workbench runs them, so the fault is the thread rather than the page or this
// host code. `just page-check` is that main-thread check and is where the hosted page's LAYOUT is
// asserted; these tests cover the seam around it.
FRAME_DOC ::
	`<html><head><meta charset="utf-8"></head><body><div id="probe" class="compass">before</div>` +
	`<script>document.getElementById('probe').textContent = 'after';</script></body></html>`

@(test)
test_the_frame_hosts_a_document_from_memory :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	testing.expect(t, show_page_html(&app, FRAME_DOC, "a test document"), "the frame must accept the document")
	pump(&app)

	root, ok := framed_root(t, &app)
	if !ok {
		return
	}
	probe, perr := sa.select_first(root, "#probe")
	if !testing.expectf(t, perr == nil, "the framed document has no #probe: %v", perr) {
		return
	}
	// The sub-document's own script ran, which is what the card page depends on for its whole carousel.
	text, terr := sa.text(probe, context.temp_allocator)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, text, "after")

	// And it is a document of its own: the id is NOT reachable from the outer root.
	outer := sa.root(app.window) or_else nil
	if outer != nil {
		_, oerr := sa.select_first(outer, "#probe")
		testing.expectf(t, oerr != nil, "a selector must not cross into the frame (got %v)", oerr)
	}
}

// The other route in: a page a generate run has already written.
@(test)
test_the_frame_hosts_a_document_from_disk :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	path, jerr := filepath.join({PARITY_DIR, "wb-frame-doc.html"}, context.temp_allocator)
	testing.expect_value(t, jerr, nil)
	if werr := os.write_entire_file(path, transmute([]u8)string(FRAME_DOC)); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", path, werr)
		return
	}
	absolute, aerr := filepath.abs(path, context.temp_allocator)
	testing.expect_value(t, aerr, nil)

	testing.expect(t, show_page_file(&app, absolute), "the frame must accept the written page")
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)
	testing.expect(t, page_pane_shown(&app), "a page that arrives opens the pane it arrived in")
	// The bar names what is on screen, which for a generated page is the path it came from.
	title, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	testing.expect_value(t, title, absolute)

	if root, ok := framed_root(t, &app); ok {
		_, perr := sa.select_first(root, "#probe")
		testing.expectf(t, perr == nil, "the page from disk did not parse: %v", perr)
	}
}

// The framed document's root element, through the frame behavior's `document` property.
@(private = "file")
framed_root :: proc(t: ^testing.T, app: ^App) -> (root: sa.Element, ok: bool) {
	asset, has_asset := page_frame_asset(app)
	if !testing.expect(t, has_asset, "the frame behavior must be reachable") {
		return nil, false
	}
	document, derr := sa.asset_get(asset, "document")
	defer sa.value_clear(&document)
	if !testing.expectf(t, derr == nil, "the frame has no document: %v", derr) {
		return nil, false
	}
	element, eerr := sa.element_from_value(&document)
	if !testing.expectf(t, eerr == nil, "the frame's document is not an element: %v", eerr) {
		return nil, false
	}
	return element, true
}

// "view page" opens what the selected scenario HAS, newest first — not what the format dropdown names.
//
// Two failures this pins, both reported from the window: following the dropdown made the button claim there
// was nothing to view after switching the format (the pages were right there), and an earlier version tracked
// "the last page this run wrote", which after a 110-scenario batch is never the one you were looking at.
// The message also has to name the scenario and where it looked; a bare "nothing" leaves the user choosing
// between the wrong directory, the wrong format and a run they never did.
@(test)
test_view_page_opens_what_the_scenario_has :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#outdir", PARITY_DIR)
	app.selected = 0
	name := app.scenarios[0].name

	directory, _ := filepath.abs(PARITY_DIR, context.temp_allocator)
	cards, _ := filepath.join({directory, fmt.tprintf("%s.html", name)}, context.temp_allocator)
	text, _ := filepath.join({directory, fmt.tprintf("%s.txt", name)}, context.temp_allocator)
	os.remove(cards)
	os.remove(text)

	// Nothing written for it yet.
	_, _, found, why := selected_output(&app)
	testing.expect(t, !found, "with nothing on disk there is nothing to view")
	testing.expectf(t, strings.contains(why, name), "the message names the scenario: %s", why)
	testing.expectf(t, strings.contains(why, "generate"), "and what to do about it: %s", why)
	testing.expectf(t, strings.contains(why, directory), "and where it looked: %s", why)

	// A CARDS page: recognised by the carousel's own id rather than by the extension, because both html
	// formats write `.html`.
	CARDS_DOC :: `<html><head><meta charset="utf-8"></head><body><div class="track" id="nc-track"></div></body></html>`
	if werr := os.write_entire_file(cards, transmute([]u8)string(CARDS_DOC)); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", cards, werr)
		return
	}
	defer os.remove(cards)

	shown, kind, exists, _ := selected_output(&app)
	testing.expect(t, exists, "the page on disk is found")
	testing.expect_value(t, shown, cards)
	testing.expect_value(t, kind, Output_Kind.Cards)

	// A TEXT output on its own resolves too — the format dropdown still says html-cards and is not
	// consulted. (WHICH of two outputs wins when both exist is a modification-time comparison, and two
	// files written in the same breath can share a tick, so that is not what this asserts: what matters is
	// that each kind resolves, and that the kind always describes the file that was chosen.)
	set_input(&app, "#format", "html-cards")
	os.remove(cards)
	if werr := os.write_entire_file(text, transmute([]u8)string("North opens 1C\n")); werr != nil {
		testing.expectf(t, false, "could not write %s: %v", text, werr)
		return
	}
	defer os.remove(text)

	newest, newest_kind, newest_found, _ := selected_output(&app)
	testing.expect(t, newest_found, "the text output is found")
	testing.expect_value(t, newest, text)
	testing.expect_value(t, newest_kind, Output_Kind.Text)

	// And with both on disk, whichever wins, its kind is the kind of the file that won.
	if werr := os.write_entire_file(cards, transmute([]u8)string(CARDS_DOC)); werr == nil {
		both, both_kind, both_found, _ := selected_output(&app)
		testing.expect(t, both_found, "with both on disk, one of them is chosen")
		testing.expect(t, both == cards || both == text, "and it is one of the two")
		testing.expect_value(t, both_kind, file_kind(both))
	}

	// A HANDVIEWER page is the third kind, and it is told apart by what is IN the file: pages of iframes onto
	// bridgebase.com cannot be hosted in the frame, so they go to the browser instead.
	HANDVIEWER_DOC :: `<html><head><meta charset="utf-8"></head><body><iframe src="https://www.bridgebase.com/tools/handviewer.html?lin=x"></iframe></body></html>`
	testing.expect_value(t, file_kind(text), Output_Kind.Text)
	if werr := os.write_entire_file(cards, transmute([]u8)string(HANDVIEWER_DOC)); werr == nil {
		testing.expect_value(t, file_kind(cards), Output_Kind.Handviewer)
	}

	// An unselected list is its own message rather than a wrong path.
	app.selected = -1
	_, _, none, none_why := selected_output(&app)
	testing.expect(t, !none, "with nothing selected there is nothing to resolve")
	testing.expectf(t, strings.contains(none_why, "scenario"), "and it asks for a scenario: %s", none_why)
}

// The geometry dump: it measures the framed document, names what it could not find, and says why when
// there is nothing to measure. This is the affordance that gets a REAL window's numbers into a bug report,
// so its failure mode has to be a sentence rather than an empty pane.
@(test)
test_the_page_dump_measures_the_framed_document :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// Nothing in the frame yet.
	dump_page(&app)
	empty, _ := report_content(&app, context.temp_allocator)
	testing.expect(t, strings.contains(empty, "dump:"), "an empty frame reports why, rather than nothing")

	testing.expect(t, show_page_html(&app, FRAME_DOC, "a test document"), "the frame must accept the document")
	pump(&app)
	dump_page(&app)

	text, ok := report_content(&app, context.temp_allocator)
	testing.expect(t, ok, "the transcript is readable")
	testing.expect(t, strings.contains(text, "---- page dump: a test document ----"), "the dump names the page")
	testing.expect(t, strings.contains(text, "view "), "and reports the view size")
	testing.expect(t, strings.contains(text, ".compass"), "and measures an element it found")
	testing.expect(t, strings.contains(text, "display="), "with the computed styles that differ here")
	testing.expect(t, strings.contains(text, "MISSING"), "and names the selectors it did not find")
	testing.expect(t, strings.contains(text, "---- end of dump ----"), "and is bounded, so it can be pasted")
}

// Showing the page REPLACES the panes, and closing it puts them back — one view at a time, including when
// THE HAND PANE, and what it does and does not replace.
//
// It is a pane of the deals view rather than a view of its own, so a page arriving must leave the deals view
// ON (it used to replace it) - and About, which replaces everything, must still take it off screen.
@(test)
test_the_hand_pane_opens_beside_the_controls :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	testing.expect_value(t, current_view(&app), View.Panes)
	testing.expect(t, !page_pane_shown(&app), "the pane starts closed - there is nothing in it")

	testing.expect(t, show_page_html(&app, FRAME_DOC, "a test document"), "the frame must accept the document")
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)
	testing.expect(t, page_pane_shown(&app), "the page opened the pane")
	testing.expect(t, !effective_display_is_hidden(&app, ".work"), "and the controls are still beside it")
	title, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	testing.expect_value(t, title, "a test document")

	// About replaces the whole view, pane included.
	show_about(&app, true)
	testing.expect_value(t, current_view(&app), View.About)
	// The DEALS VIEW goes off screen and takes the pane with it. The pane`s own `display` is untouched -
	// `effective_display_is_hidden` reads one element rather than the chain - and that is exactly what lets
	// it come back below still open.
	testing.expect(t, effective_display_is_hidden(&app, ".panes"), "About must take the deals view off screen")

	// And leaving About comes back to the deals view with the pane still open: closing it is a decision
	// somebody makes, not something a detour does for them.
	show_about(&app, false)
	testing.expect_value(t, current_view(&app), View.Panes)
	testing.expect(t, page_pane_shown(&app), "the pane came back with the view")

	show_page_pane(&app, false)
	testing.expect(t, !page_pane_shown(&app), "and it closes when it is asked to")
	testing.expect_value(t, current_view(&app), View.Panes)
}

// `wide` hides the WORK - both panes are `width: *`, so the page takes what the controls stop asking for -
// and closing a wide pane has to bring the controls back, or the view is a scenario list and an empty
// column with no way on screen to get anything else.
@(test)
test_a_wide_hand_pane_gives_the_controls_back_when_it_closes :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	testing.expect(t, show_page_html(&app, FRAME_DOC, "a test document"), "the frame must accept the document")
	pump(&app)

	set_pane_wide(&app, true)
	testing.expect(t, pane_is_wide(&app), "wide must hide the work")
	testing.expect(t, page_pane_shown(&app), "and leave the page on screen")
	testing.expect(t, scenario_list_shown(&app), "the scenario list is what wide keeps")

	show_page_pane(&app, false)
	testing.expect(t, !pane_is_wide(&app), "closing a wide pane must unwiden it")
	testing.expect(t, !effective_display_is_hidden(&app, ".work"), "the controls have to come back")

	// Widening a CLOSED pane opens it rather than emptying the view.
	set_pane_wide(&app, true)
	testing.expect(t, page_pane_shown(&app), "wide implies open")
	set_pane_wide(&app, false)
	show_page_pane(&app, false)
}

// The scenario list folds away the way the notes view`s file list does - the same glyph, the same idiom,
// now the same splitter.
@(test)
test_the_scenario_list_folds_away :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	testing.expect(t, scenario_list_shown(&app), "the list starts on screen")
	show_scenario_list(&app, false)
	testing.expect(t, !scenario_list_shown(&app), "and folds away")
	testing.expect(t, !effective_display_is_hidden(&app, ".work"), "without taking the controls with it")
	show_scenario_list(&app, true)
	testing.expect(t, scenario_list_shown(&app), "and comes back")
}

// "as card page" is what routes an analyse run to the frame instead of to the report pane, and it must not
// add a `--html` (that would write a file nobody asked for).
@(test)
test_the_card_page_checkbox_asks_for_the_page_in_memory :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#deal", FRAME_DEAL)

	job, err := analyse_job(&app)
	testing.expect_value(t, err, "")
	app.job = job
	testing.expect(t, !job.want_page, "unticked, the run writes the text report")

	tick(&app, "#as-page")
	job_free(&app.job, app.allocator)
	ticked, terr := analyse_job(&app)
	testing.expect_value(t, terr, "")
	app.job = ticked
	testing.expect(t, ticked.want_page, "ticked, the run renders the page")
	for arg in ticked.argv {
		testing.expectf(t, arg != "--html" && arg != "-o", "the page path must not be composed: %s", arg)
	}

	args, perr := analyse.parse_args(ticked.argv, allow_stdin = false)
	defer analyse.args_free(&args)
	testing.expectf(t, perr == "", "the advisor rejected the composed argv: %s", perr)
	testing.expect_value(t, args.html_path, "")
}


// ---------------------------------------------------------------------------------------------------
// Drag and drop
//
// The engine only produces EXCHANGE events during a real system drag, which no test can stage — the same
// limit odin-sciter's own example documents. What IS testable is everything the drop hands to: the URL
// the engine passes (measured on Windows, and reproduced here as a literal), the routing by extension,
// and the command the reader is spawned with.

// The exact payload a Windows 11 / engine 6.0.4.9 drop from Explorer carried, measured: a `file:///` URL,
// percent-encoded, not a path.
@(test)
test_a_dropped_file_url_becomes_a_path :: proc(t: ^testing.T) {
	path, ok := file_url_to_path(
		"file:///C:/Users/Enerqi/dev/bridge-hand-ocr/fixtures/intobridge-2-hand-large-2.png",
		context.temp_allocator,
	)
	testing.expect(t, ok)
	testing.expect_value(t, path, "C:/Users/Enerqi/dev/bridge-hand-ocr/fixtures/intobridge-2-hand-large-2.png")

	// A screenshot in a folder with a space in its name is the ordinary case on Windows, not an edge one:
	// the percent-decode is the whole reason this is not a prefix strip.
	spaced, spaced_ok := file_url_to_path("file:///C:/My%20Deals/hand%231.png", context.temp_allocator)
	testing.expect(t, spaced_ok)
	testing.expect_value(t, spaced, "C:/My Deals/hand#1.png")

	// A bare path is taken as it stands, and nothing at all is refused rather than analysed.
	bare, bare_ok := file_url_to_path("C:/deals/hand.png", context.temp_allocator)
	testing.expect(t, bare_ok)
	testing.expect_value(t, bare, "C:/deals/hand.png")
	_, empty_ok := file_url_to_path("", context.temp_allocator)
	testing.expect(t, !empty_ok, "an empty url is not a file")
}

// The engine hands the payload over as a MAP, and the value under "file" is an ARRAY even for one file.
// Built by hand here, which is the point of `drop_file_path` being separate from the event.
@(test)
test_the_drop_payload_map_yields_the_dropped_file :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return} 	// the Value API needs the engine loaded
	defer test_app_destroy(&app)

	files := sa.value_make_array(1)
	defer sa.value_clear(&files)
	url := sa.value_from("file:///C:/deals/hand.png")
	defer sa.value_clear(&url)
	testing.expect_value(t, sa.value_set_at(&files, 0, &url), nil)

	data: sa.Value
	sa.value_init(&data)
	defer sa.value_clear(&data)
	testing.expect_value(t, sa.value_set(&data, "file", &files), nil)

	path, ok := drop_file_path(&data, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, path, "C:/deals/hand.png")

	// A drop carrying no file at all is refused rather than guessed at — this is what Linux delivers (an
	// empty map), and what the status line reports.
	empty: sa.Value
	sa.value_init(&empty)
	defer sa.value_clear(&empty)
	_, empty_ok := drop_file_path(&empty, context.temp_allocator)
	testing.expect(t, !empty_ok, "an empty payload carries nothing to open")
}

// What a dropped file means. Every branch here is something the window already knew how to do.
@(test)
test_a_drop_is_routed_by_what_the_file_is :: proc(t: ^testing.T) {
	testing.expect_value(t, drop_action("C:/shots/hand.png"), Drop_Action.Read_Image)
	testing.expect_value(t, drop_action("C:/shots/HAND.JPEG"), Drop_Action.Read_Image) // case is not a format
	testing.expect_value(t, drop_action("C:/deals/board.pbn"), Drop_Action.Deal_File)
	testing.expect_value(t, drop_action("C:/deals/board.lin"), Drop_Action.Deal_File)
	testing.expect_value(t, drop_action("w:/deals/2c-opener.html"), Drop_Action.Page)
	testing.expect_value(t, drop_action("C:/notes/system.bml"), Drop_Action.Unknown)
	testing.expect_value(t, drop_action("C:/no-extension"), Drop_Action.Unknown)
}

// The reader's command line. `--project` is the load-bearing flag: hand-ocr's PROJECT environment has the
// vision stack, and the script's own PEP-723 environment does not (it carries docopt and nothing else), so
// running the script without it fails on `import cv2` rather than on anything to do with the picture.
@(test)
test_the_ocr_command_runs_hand_ocr_in_its_own_project :: proc(t: ^testing.T) {
	command := ocr_command("C:/shots/hand.png", "C:/dev/bridge-hand-ocr", context.temp_allocator)

	testing.expect_value(t, command[0], "uv")
	testing.expect_value(t, command[1], "run")
	testing.expect_value(t, command[2], "--project")
	testing.expect_value(t, command[3], "C:/dev/bridge-hand-ocr")
	testing.expect(t, strings.has_suffix(command[5], "hand-ocr.py"), "the script comes from that checkout")
	testing.expect(t, strings.contains(command[5], "bridge-hand-ocr"), "and not from anywhere else")
	testing.expect_value(t, command[6], "C:/shots/hand.png")
	testing.expect_value(t, command[7], "--format")
	testing.expect_value(t, command[8], "pbn") // the one format `analyse.parse_args` reads back
}

// A dropped image is the analyse BUTTON with the deal arriving from a picture: the panel's controls have
// to reach the run unchanged, or the drop would silently analyse something other than what the window says.
@(test)
test_a_dropped_image_carries_the_analyse_panels_settings :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#sample", "200")
	type_into(&app, "#contract", "3NT")
	type_into(&app, "#target", "9")
	tick(&app, "#as-page")

	job, err := ocr_job(&app, "C:/shots/hand.png")
	testing.expect_value(t, err, "")
	app.job = job
	testing.expect_value(t, job.kind, Job_Kind.Ocr)
	testing.expect_value(t, job.image, "C:/shots/hand.png")
	testing.expect(t, job.want_page, "ticked, the drop draws the card page")

	// The argv carries no deal yet — that is what hand-ocr is for — so it is checked by appending one, which
	// is exactly what `work_ocr` does with what it read.
	argv := make([dynamic]string, 0, len(job.argv) + 1, context.temp_allocator)
	append(&argv, ..job.argv)
	append(&argv, FRAME_DEAL)

	args, perr := analyse.parse_args(argv[:], allow_stdin = false)
	defer analyse.args_free(&args)
	testing.expectf(t, perr == "", "the advisor rejected the composed argv: %s", perr)
	testing.expect_value(t, args.sample, 200)
	testing.expect_value(t, args.contract, "3NT")
	testing.expect_value(t, args.target, 9)
	testing.expect_value(t, args.html_path, "") // the page is asked for in memory, as with the button
}

// The plumbing, end to end, against the REAL hand-ocr: `--demo` skips the vision stack (it emits a
// hardcoded deal), so this is `uv` + the checkout + the argv + the format, in about two seconds and with
// no opencv needed. SKIPPED rather than failed where hand-ocr is not checked out — it is a sibling repo
// and an optional one, and a test that fails on its absence would fail on every machine but this one.
@(test)
test_hand_ocr_answers_with_a_deal_the_advisor_can_read :: proc(t: ^testing.T) {
	dir := hand_ocr_dir(context.temp_allocator)
	if !os.is_dir(dir) {
		log.warnf("hand-ocr is not at %s — skipping the reader plumbing test", dir)
		return
	}

	command := ocr_command("--demo", dir, context.temp_allocator)
	state, stdout, stderr, exec_err := os.process_exec({command = command}, context.temp_allocator)
	if exec_err != nil {
		log.warnf("could not run uv (%v) — skipping the reader plumbing test", exec_err)
		return
	}
	testing.expectf(t, state.success, "hand-ocr exited with %d: %s", state.exit_code, string(stderr))

	deal := strings.trim_space(string(stdout))
	testing.expectf(t, strings.contains(deal, "[Deal"), "hand-ocr printed no deal tag: %q", deal)

	// The point of the whole exchange: what it prints is what the advisor reads.
	args, perr := analyse.parse_args({deal}, allow_stdin = false)
	defer analyse.args_free(&args)
	testing.expectf(t, perr == "", "the advisor rejected what hand-ocr printed: %s", perr)
	boards, berr := analyse.resolve_boards(args.text)
	defer delete(boards)
	testing.expect_value(t, berr, "")
	testing.expect_value(t, len(boards), 1)
}

// ---- the BML editor -----------------------------------------------------------------------------
//
// Four seams, and each of them has a way of failing silently:
//   * the corpus is found by walking UP from the working directory, which is a different number of levels
//     for `just test-workbench` than for the built exe;
//   * the colour is applied by the document's own script through an API this side cannot read back, so the
//     script reports a COUNT and that count is the assertion;
//   * a save rewrites a file of the user's notes, and the line endings and the trailing newline are what
//     would turn a one-word edit into a diff of every line;
//   * the mark names are written twice — once in the script, once in the stylesheet — and a mark nothing
//     styles is invisible rather than broken.

// The notes are two directories above this one, and `bml_docs_dir` is what has to find them. A test binary
// runs with the working directory `just` was invoked from, which is `deal-simulations/odin-sims`.
@(test)
test_the_bml_corpus_is_found_by_walking_up :: proc(t: ^testing.T) {
	dir, note := bml_docs_dir(context.temp_allocator)
	if dir == "" {
		log.warnf("no .bml corpus above the working directory (%s) — skipping", note)
		return
	}
	testing.expect(t, bml_corpus_at(dir), "the directory it named does not hold the corpus marker")

	names := list_bml_files(dir, context.temp_allocator)
	testing.expect(t, len(names) > 5, "the corpus should hold more than a handful of .bml files")
	testing.expect(t, slice.contains(names, BML_CORPUS_MARKER), "the root document should be in the list")
	for name in names {
		testing.expectf(t, strings.has_suffix(name, ".bml"), "%q is not a .bml file", name)
	}
	// Sorted, because the picker shows them in this order and the first one is what the editor opens.
	testing.expect(t, slice.is_sorted(names), "the file list should be sorted by name")
}

// Opening a file fills the widget and the picker agrees with it afterwards.
@(test)
test_the_bml_editor_opens_a_file :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	pump(&app)

	ok, why := open_bml(&app, BML_CORPUS_MARKER)
	testing.expectf(t, ok, "could not open %s: %s", BML_CORPUS_MARKER, why)
	if !ok {
		return
	}
	pump(&app)

	source, got := bml_source(&app, context.temp_allocator)
	testing.expect(t, got, "the buffer could not be read back")
	testing.expect(t, len(source) > 100, "the buffer is too small to be the root document")
	testing.expect(t, strings.contains(source, "#INCLUDE"), "the root document is the one with the includes")
	// The widget is fed `\n` whatever the file holds — a `\r` reaching it would show up as a glyph.
	testing.expect(t, !strings.contains(source, "\r"), "no carriage return should reach the widget")
	testing.expect(t, app.bml_crlf, "the corpus is CRLF, and that has to be remembered for the save")
	// The list marks what is open, which is where "which file is this?" is answered now that the picker is
	// a sidebar rather than a dropdown.
	marked, merr := sa.select_all(find(&app, "#bml-list"), ".row.sel", context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, len(marked), 1)
	open_name, _ := sa.attribute(marked[0], "data-file", context.temp_allocator)
	testing.expect_value(t, open_name, BML_CORPUS_MARKER)
}

// The colour. `bmlColorize()` is the document's own function and it hands back how many marks it applied;
// this is the only visible result, because a mark is not an attribute and reads back through a `Range` or
// not at all. A zero here means the script did not run — a syntax error in it, or `Range.applyMark` gone.
@(test)
test_the_bml_editor_colours_what_it_loads :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = "" // no corpus needed: the buffer is written directly

	set_bml_source(
		&app,
		strings.join(
			{
				"#+TITLE: a title",
				"",
				"* Opening bids",
				"",
				"1C = 16+ hcp, see [relay](#Relay)",
				"  (1H) = an overcall of 8+ !h",
			},
			"\n",
			context.temp_allocator,
		),
	)
	pump(&app)

	marks := colorize_bml(&app)
	testing.expect(t, marks >= 6, "every one of those lines carries at least one token to colour")
}

// A save must give the file back BYTE FOR BYTE when nothing was edited. That is not a tautology here: the
// widget hands its content back as `\n` with no trailing newline, and the corpus is CRLF with one — so a
// round trip that did not restore both would rewrite every line of every file anyone opened.
@(test)
test_a_bml_save_round_trips_the_bytes :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// A scratch copy, not the user's notes: this test writes.
	dir := filepath.join({"target", "debug"}, context.temp_allocator) or_else "."
	name := "wb-editor-round-trip.bml"
	path := filepath.join({dir, name}, context.temp_allocator) or_else name
	original := "#+TITLE: round trip\r\n\r\n* Opening bids\r\n\r\n1C = 16+ hcp\r\n  1D = 0-7 hcp\r\n"
	if err := os.write_entire_file(path, transmute([]u8)original); err != nil {
		log.warnf("could not write %s (%v) — skipping", path, err)
		return
	}
	defer os.remove(path)

	app.docs = dir
	pump(&app)

	ok, why := open_bml(&app, name)
	testing.expectf(t, ok, "could not open the scratch file: %s", why)
	if !ok {
		return
	}
	pump(&app)

	written, save_why := save_bml(&app)
	testing.expectf(t, written, "could not save the scratch file: %s", save_why)

	back, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, string(back), original)
}

// The preview renders THE BUFFER — the point of the whole editor, and the thing the python reference could
// not do (it renders a path). Asserted through the frame's own document rather than by looking at the html
// string: what matters is that a document came out and the engine took it.
@(test)
test_the_bml_preview_renders_the_buffer :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""
	app.bml_open = "scratch.bml"
	defer app.bml_open = ""

	set_bml_source(&app, "#+TITLE: previewed\n\n* Slam bidding\n\n4N = RKB\n")
	pump(&app)

	ok, why := preview_bml(&app)
	testing.expectf(t, ok, "the preview did not render: %s", why)
	if !ok {
		return
	}
	pump(&app)

	heading, found := preview_selection(&app, "h1")
	testing.expect(t, found, "the preview has no <h1> — the document did not reach the frame")
	testing.expect_value(t, heading, "Slam bidding")

	// The bid table is what a `.bml` document is FOR, and it is the part of the renderer with structure:
	// a heading would still be there if the bid-table path had produced nothing.
	_, table := preview_selection(&app, "div.bidtable")
	testing.expect(t, table, "the preview has no bid table")
}

// The same, with the notes' OWN stylesheet inlined — which is the shape the application actually loads, and
// the shape that has to survive the width-media stripper. Hidden frame, for the reason in `preview_selection`.
@(test)
test_the_preview_carries_the_notes_stylesheet :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir, note := bml_docs_dir(context.temp_allocator)
	if dir == "" {
		log.warnf("no corpus (%s) — skipping", note)
		return
	}
	app.docs = dir
	app.bml_open = "scratch.bml"
	defer app.bml_open = ""

	set_bml_source(
		&app,
		strings.join({"#+TITLE: styled", "", "* Opening bids", "", "1C = 16+ hcp"}, "\n", context.temp_allocator),
	)
	pump(&app)

	ok, why := preview_bml(&app)
	testing.expectf(t, ok, "the preview did not render: %s", why)
	pump(&app)

	heading, found := preview_selection(&app, "h1")
	testing.expect(t, found, "the styled preview has no <h1>")
	testing.expect_value(t, heading, "Opening bids")
}

// The preview document is SELF-CONTAINED: the stylesheet inlined, and no `<link>` left to fetch. A webfont
// `<link>` is an outbound https request from a desktop window, and a relative `bml.css` would resolve
// against a base url this frame does not have — either way the page arrives unstyled and nothing says why.
@(test)
test_the_preview_document_fetches_nothing :: proc(t: ^testing.T) {
	app: App
	app.docs = "" // no stylesheet to find, which is the harder case: the tags still have to go
	rendered :=
		`<html><head><link rel="stylesheet" type="text/css" href="bml.css" />` +
		`<link href="https://fonts.googleapis.com/css?family=Open Sans" rel="stylesheet" />` +
		`<title>t</title></head><body class="content"><h1>H</h1></body></html>`

	page := preview_document(&app, rendered, allocator = context.temp_allocator)
	testing.expect(t, !strings.contains(page, "<link"), "no <link> may survive into the preview")
	testing.expect(t, !strings.contains(page, "fonts.googleapis.com"), "the webfont request must be gone")
	testing.expect(t, strings.contains(page, "<style>"), "the stylesheet is inlined instead")
	testing.expect(t, strings.contains(page, "<h1>H</h1>"), "the body must come through untouched")
	testing.expect(t, strings.contains(page, "<title>t</title>"), "and so must the rest of the head")
}

// The mark names are written twice — `BML_MARKS` in the script, `::mark(...)` in the stylesheet — and the
// two lists have to agree. A mark nothing styles is not an error: it is text that quietly stays grey.
@(test)
test_bml_marks_are_styled :: proc(t: ^testing.T) {
	document := compose_document(context.temp_allocator)

	names, found := marks_declared_by_the_script(document, "BML_MARKS", context.temp_allocator)
	testing.expect(t, found, "the script's BML_MARKS list is not in the document")
	testing.expect(t, len(names) >= 6, "the colorizer should name at least six token classes")
	for name in names {
		rule := fmt.tprintf("::mark(%s)", name)
		testing.expectf(t, strings.contains(document, rule), "%s has no %s rule in the stylesheet", name, rule)
	}

	// The same for the diagnostics' own marks, which are a second list for a second reason: they are
	// CLEARED separately (an edit invalidates a position, but not a token's colour), and an unstyled
	// squiggle is invisible in exactly the way an unstyled token is.
	problems, problems_found := marks_declared_by_the_script(document, "BML_PROBLEM_MARKS", context.temp_allocator)
	testing.expect(t, problems_found, "the script's BML_PROBLEM_MARKS list is not in the document")
	testing.expect_value(t, len(problems), 2)
	for name in problems {
		rule := fmt.tprintf("::mark(%s)", name)
		testing.expectf(t, strings.contains(document, rule), "%s has no %s rule in the stylesheet", name, rule)
	}
}

// THE CARET HAS TO BE VISIBLE, and the caret is the only thing that says a pane is an editor. Two ways it
// went missing, both silent, both here:
//
//  1. Sciter's caret colour is `text-selection-caret-color`. The browsers' `caret-color` is not a property
//     this engine has, so spelling it that way parses, matches, and paints the engine's own default —
//     black, which is `--sunken` on this sheet. A property read back EMPTY is that mistake.
//  2. The engine paints a caret only in a FOCUSED widget, and opening the view used to focus nothing.
//
// The colour is read as a computed style rather than grepped out of the sheet, because the point is what
// the engine resolved — a property it does not know is exactly what a `var()` that resolved would look
// like in the text.
@(test)
test_the_editor_has_a_visible_caret :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)

	text := find(&app, "#bml-text")
	testing.expect(t, text != nil, "there is no source pane")
	if text == nil {return}

	colour, cerr := sa.style(text, "text-selection-caret-color", context.temp_allocator)
	testing.expect_value(t, cerr, nil)
	testing.expectf(t, colour != "", "the engine does not know text-selection-caret-color")
	// --accent is #89b4fa. Whatever spelling comes back, it must not be the black default nor transparent,
	// either of which is an invisible caret on the sunken background.
	testing.expectf(
		t,
		!strings.contains(colour, "transparent") && !strings.contains(colour, "0,0,0"),
		"the caret is %q against a #11111b background",
		colour,
	)

	// And something holds the caret the moment the view opens.
	state, serr := sa.element_state(text)
	testing.expect_value(t, serr, nil)
	testing.expect(t, .FOCUS in state, "the source pane opens without the focus, so it paints no caret")
}

// The live preview is a DEBOUNCE whose delay is the last render`s own cost, and this is the arithmetic of
// it: a cheap document waits the base, an expensive one waits proportionally longer, and nothing waits more
// than the cap. Measured costs are what the numbers here stand for - ~100ms for a chapter shown as one
// section, ~1s for the assembled root shown whole.
@(test)
test_the_live_preview_delay_scales_with_what_a_render_costs :: proc(t: ^testing.T) {
	app: App
	app.bml_live_base = LIVE_PREVIEW_BASE

	// A chapter: four times 100ms is under the base, so the base is what a person waits.
	app.bml_preview_cost = 100 * time.Millisecond
	testing.expect_value(t, live_preview_delay(&app), LIVE_PREVIEW_BASE)

	// Half a second a render, and the delay follows it rather than the base.
	app.bml_preview_cost = 500 * time.Millisecond
	testing.expect_value(t, live_preview_delay(&app), 2 * time.Second)

	// The assembled root. Four seconds would be the scale; the cap is what it gets.
	app.bml_preview_cost = time.Second
	testing.expect_value(t, live_preview_delay(&app), LIVE_PREVIEW_MAX)

	// And WORKBENCH_LIVE_MS=0 turns the whole thing off - `preview` goes back to being the only render.
	app.bml_live_base = 0
	testing.expect_value(t, live_preview_delay(&app), 0)
}

// A render must not start inside a render. It pumps the engine to build the document in the frame, so a
// timer or a click delivered during that pump reaches the same code with a half-built document in the pane -
// which is why the guard is in `preview_bml` itself and not in the live path that made it necessary.
//
// The same test pins the two numbers the live preview reads: what the render COST (its debounce is scaled by
// it) and a fingerprint of the text the pane is showing (an idle timer over an unchanged buffer must not
// render at all). Hidden frame, for the reason in `preview_selection`.
@(test)
test_a_preview_refuses_to_start_inside_another_one :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""
	app.bml_open = "scratch.bml"
	defer app.bml_open = ""

	set_bml_source(&app, "#+TITLE: live\n\n* Slam bidding\n\n4N = RKB\n")
	pump(&app)

	app.bml_rendering = true
	refused, why := preview_bml(&app)
	testing.expect(t, !refused, "a render started inside another one")
	testing.expect_value(t, why, "the preview is still rendering")
	app.bml_rendering = false

	ok, reason := preview_bml(&app)
	testing.expectf(t, ok, "the preview did not render: %s", reason)
	pump(&app)
	testing.expect(t, app.bml_preview_cost > 0, "the render cost was not measured - the debounce cannot scale")
	testing.expect(t, app.bml_rendered != 0, "the rendered text was not fingerprinted")
	testing.expect(t, !app.bml_rendering, "the guard was left set - nothing would ever render again")

	// The fingerprint is of the TEXT, so the same buffer rendered twice is the same number: that identity is
	// what makes a timer over an untouched buffer free.
	was := app.bml_rendered
	_, _ = preview_bml(&app)
	pump(&app)
	testing.expect_value(t, app.bml_rendered, was)
}
// COLOURING MUST NOT TOUCH THE CARET OR THE SELECTION. It is a `Range` per token over the very text someone
// is editing, so "the caret jumped" and "there is selection paint where there is no selection" both have
// the colorizer as their first suspect. This is the measurement that answers it: the widget's own
// `selectionStart`/`selectionEnd` (an array `[row, col]`, reached through the plaintext asset - script sees
// `undefined`), read either side of a whole pass and a dirty pass, and either side of a RENDER, which is the
// other thing that runs while someone types.
@(test)
test_colouring_does_not_move_the_caret_or_the_selection :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	set_bml_source(
		&app,
		strings.join(
			{"#+TITLE: probe", "", "* Head one", "", "1C = strong, see [x](#Head two)", "  1D = weak", "", "* Head two", "", "2C = game force"},
			"\n",
			context.temp_allocator,
		),
	)
	pump(&app)
	_ = colorize_bml(&app)
	pump(&app)

	element := find(&app, "#bml-text")
	testing.expect(t, element != nil, "there is no source pane")
	if element == nil {return}
	sa.set_focus(element)
	pump(&app)
	asset, aerr := sa.element_asset(element, "plaintext")
	testing.expect_value(t, aerr, nil)

	// Put the caret on the line with the most to colour on it - a call, an `=`, a cross-reference.
	set_caret_row(&app, 4)
	pump(&app)
	before := selection_of(asset)
	testing.expect_value(t, caret_row(&app), 4)

	testing.expect_value(t, colorize_bml(&app) > 0, true)
	pump(&app)
	testing.expect_value(t, selection_of(asset), before)
	testing.expect_value(t, caret_row(&app), 4)

	// The dirty pass, which is the one that runs on every burst of typing.
	dirty, derr := sa.eval(app.window, "bmlColorizeDirty()")
	sa.value_clear(&dirty)
	testing.expect_value(t, derr, nil)
	pump(&app)
	testing.expect_value(t, selection_of(asset), before)

	// And a render, which the live preview runs from under the same keystrokes. Hidden frame, for the reason
	// in `preview_selection`.
	app.bml_open = "scratch.bml"
	defer app.bml_open = ""
	if ok, why := preview_bml(&app); !ok {
		log.warnf("the preview did not render (%s) - skipping the render half", why)
		return
	}
	pump(&app)
	testing.expect_value(t, selection_of(asset), before)
	testing.expect_value(t, caret_row(&app), 4)
}

// `[row, col] -> [row, col]`, or a word saying why not. A string because it is only ever compared with
// another reading of itself.
@(private = "file")
selection_of :: proc(asset: ^sciter.Som_Asset_T) -> string {
	pair :: proc(asset: ^sciter.Som_Asset_T, name: string) -> string {
		value, err := sa.asset_get(asset, name)
		defer sa.value_clear(&value)
		if err != nil {
			return "unreadable"
		}
		if kind, _ := sa.value_type(&value); kind != .ARRAY {
			return "not-a-position"
		}
		row, _ := sa.value_at(&value, 0)
		col, _ := sa.value_at(&value, 1)
		defer sa.value_clear(&row)
		defer sa.value_clear(&col)
		r, rerr := sa.value_to_int(&row)
		c, cerr := sa.value_to_int(&col)
		if rerr != nil || cerr != nil {
			return "not-a-position"
		}
		return fmt.tprintf("%d:%d", r, c)
	}
	return fmt.tprintf("%s -> %s", pair(asset, "selectionStart"), pair(asset, "selectionEnd"))
}
/*
A ZOOMED FIELD STILL HAS ITS TEXT IN THE MIDDLE OF IT.

The engine`s own sheet gives `input[type=text]` and `select` a fixed `height: 1.4em`, and the caption inside
does not stay centred in that box as `zoom` goes up - it walks DOWNWARDS, until at a high zoom the text is
sitting on the bottom border with its descenders cut off. `height: auto` is the fix (the control sizes itself
to what it is showing) and this is the measurement that says so, because nothing in the geometry API can see
it: the caption is INTERNAL to the control (`child_count` is 0, and a composite control`s internals take no
author CSS), so the only witness is the pixels.

So: paint the view, find the rows inside the field that have ink in them, and check the gap above the ink
against the gap below it. Balanced at 100% either way - the bug is what zoom does to it (13/13 at 100%,
22/11 at 133% with the engine`s height, 13/13 and 17/17 with this one).

Only up to 133%: above that this windowless harness reports the whole field as bright, which is a property of
the harness rather than of the layout (the boxes and the ratios stay sane) and would make the check a coin
toss. The mechanism is the same at every step, so the first three answer for the rest.
*/
@(test)
test_a_zoomed_field_keeps_its_text_centred :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	set_input(&app, "#outdir", "www")
	pump(&app)
	defer for _ in 0 ..< 3 {_ = zoom_step(&app, -1)} // leave the window as it was found

	for step in 0 ..= 3 {
		if step > 0 {
			_ = zoom_step(&app, 1)
		}
		pump(&app)
		above, below, ok := ink_gaps(&app, "#outdir")
		if !ok {
			log.warn("the field has no ink in it - skipping this step")
			continue
		}
		testing.expectf(
			t,
			abs(above - below) <= 3,
			"at zoom %.2f the text sits %dpx from the top and %dpx from the bottom of its field",
			zoom_factor(&app),
			above,
			below,
		)
	}
}

// The gap above and below the INK inside a control, in painted pixels. A row counts as ink when more than a
// caret`s width of it is brighter than the field it sits on.
@(private = "file")
ink_gaps :: proc(app: ^App, selector: string) -> (above: int, below: int, ok: bool) {
	element := find(app, selector)
	if element == nil {
		return 0, 0, false
	}
	box, berr := sa.location(element, .Border, .Root)
	if berr != nil {
		return 0, 0, false
	}
	sa.paint_windowless(&g_view)
	top, bottom := -1, -1
	for y := box.y; y < box.y + box.height; y += 1 {
		if y < 0 || y >= 780 {
			continue
		}
		bright := 0
		for x := box.x + 4; x < min(box.x + box.width - 4, 1120); x += 1 {
			if x < 0 {
				continue
			}
			r, g, b, _ := sa.windowless_pixel(&g_view, x, y)
			if int(r) + int(g) + int(b) > 3 * 120 { 	// the field is #313244, the ink #cdd6f4
				bright += 1
			}
		}
		if bright > 2 {
			if top < 0 {
				top = int(y)
			}
			bottom = int(y)
		}
	}
	if top < 0 {
		return 0, 0, false
	}
	return top - int(box.y), int(box.y + box.height) - bottom, true
}
// Typing must not re-colour the whole chapter. It used to: the `change` handler ran a whole-buffer pass
// every 40ms, which is a `Range` per token over every line — 49ms on a 1400-line chapter and 203ms on the
// 5300-line one, measured, and felt as a keyboard that lags behind a burst of typing while a single
// keypress looks fine.
//
// The dirty pass reads each line and marks only the ones whose text is not the text they were last marked
// with, which costs 2-8ms of walking and no Range work at all. THIS test is that property: a dirty pass
// straight after a whole one must mark NOTHING. If the per-line memory ever stops working the assertion
// fails here rather than being felt as a slow editor months later.
@(test)
test_a_dirty_colour_pass_skips_the_lines_that_did_not_change :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = "" // no corpus needed: the buffer is written directly

	set_bml_source(
		&app,
		strings.join(
			{"#+TITLE: a title", "", "* Opening bids", "", "1C = 16+ hcp, see [relay](#Relay)", "  (1H) = an overcall of 8+ !h"},
			"\n",
			context.temp_allocator,
		),
	)
	pump(&app)

	whole := colorize_bml(&app)
	testing.expect(t, whole > 0, "the whole pass marked nothing — the colorizer did not run")

	dirty, err := sa.eval(app.window, "bmlColorizeDirty()")
	defer sa.value_clear(&dirty)
	testing.expect_value(t, err, nil)
	marked, ierr := sa.value_to_int(&dirty)
	testing.expect_value(t, ierr, nil)
	testing.expectf(t, marked == 0, "a dirty pass re-marked %d tokens on text nobody had touched", marked)

	// And the HOST entry point is unaffected by that memory: a new file must colour whether or not the
	// widget reused its line elements to hold it.
	set_bml_source(&app, "* Another chapter\n\n2N = 20-21 balanced\n")
	pump(&app)
	testing.expect(t, colorize_bml(&app) > 0, "a freshly loaded buffer came back uncoloured")
}

// The editor is one of four views that REPLACE each other; two of them on screen at once was the bug the
// `View` enum exists to make impossible.
@(test)
test_the_editor_view_replaces_the_panes :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	pump(&app)

	testing.expect_value(t, current_view(&app), View.Panes)
	show_editor(&app)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Editor)
	testing.expect(t, effective_display_is_hidden(&app, ".panes"), "the panes must be off screen")
	testing.expect(t, app.bml_open != "", "the first visit should open a file")

	show_view(&app, .Panes)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)
	testing.expect(t, effective_display_is_hidden(&app, "#editview"), "the editor must be off screen")
}

// Switching files over EDITED text is refused once, and the picker is put back on the file that is really
// open — otherwise the control and the buffer would disagree about which file `save` writes to.
@(test)
test_switching_away_from_unsaved_text_is_refused_once :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	if len(app.bml_names) < 2 {
		log.warn("fewer than two .bml files — nothing to switch to; skipping")
		return
	}
	pump(&app)

	first, second := app.bml_names[0], app.bml_names[1]
	ok, why := open_bml(&app, first)
	testing.expectf(t, ok, "could not open %s: %s", first, why)
	if !ok {
		return
	}
	pump(&app)
	testing.expect(t, !bml_modified(&app), "a freshly loaded buffer is not modified")

	// A KEY, delivered to the focused widget, because that is what actually sets `isModified`. Two things
	// measured while getting here, both worth knowing before writing another test against this widget:
	// `appendLine` through a script does nothing at all in a windowless view (no text, no modification),
	// and a `.CHAR` key marks the buffer modified WITHOUT inserting the character. So this asserts the
	// FLAG's effect on the guard, which is what the guard reads; the discard itself is what reloads the
	// text either way.
	element := find(&app, "#bml-text")
	sa.set_focus(element)
	pump(&app)
	processed, kerr := sa.send_key(element, .CHAR, u32('X'))
	pump(&app)
	testing.expect(t, processed && kerr == nil, "the widget did not take the key")
	if !bml_modified(&app) {
		log.warn("the widget does not report a typed character as a modification; skipping the guard")
		return
	}

	switch_bml_file(&app, second)
	pump(&app)
	testing.expect_value(t, app.bml_open, first) // refused
	// And the LIST still says which file is really open, marked as having unsaved changes.
	marked, merr := sa.select_all(find(&app, "#bml-list"), ".row.sel", context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, len(marked), 1)
	open_name, _ := sa.attribute(marked[0], "data-file", context.temp_allocator)
	testing.expect_value(t, open_name, first)
	classes, _ := sa.attribute(marked[0], "class", context.temp_allocator)
	testing.expect(t, strings.contains(classes, "dirty"), "the open row should show it has unsaved changes")

	switch_bml_file(&app, second)
	pump(&app)
	testing.expect_value(t, app.bml_open, second) // the second attempt discards and loads
}

// Point `app` at the real corpus, or say why not. A skip rather than a failure: the tests that need the
// notes are testing the seam onto them, and a checkout without them is a thing that happens.
@(private = "file")
editor_corpus :: proc(t: ^testing.T, app: ^App) -> bool {
	dir, note := bml_docs_dir(context.temp_allocator)
	if dir == "" {
		log.warnf("no .bml corpus (%s) — skipping", note)
		return false
	}
	app.docs = dir
	app.bml_names = list_bml_files(dir, context.temp_allocator)
	draw_bml_files(app)
	return len(app.bml_names) > 0
}

// One element's text out of the PREVIEW frame's sub-document. The frame is a document of its own, so this
// goes through the frame behavior's `document` property the way `focus_page` does.
//
// TWO WINDOWLESS-ONLY LANDMINES, measured while writing these tests, and both take the PROCESS down rather
// than returning an error (the runner then hangs, because its crash handler touches the engine from another
// thread and trips the one-thread rule):
//
//   * `sa.location` on a `<frame>` ELEMENT once a document is loaded into it. An EMPTY frame measures fine,
//     which is the trap — the same call in `test_the_editor_split_gives_both_halves_a_box` is safe because
//     nothing has been previewed yet.
//   * reaching into the frame's document AT ALL while the frame is DISPLAYED. Which is why the preview test
//     below never calls `show_editor`: it previews into a hidden frame and reads it there.
//
// The real WINDOW does neither of these things wrong — `focus_page` has always reached into a visible card
// page — so this is a property of the windowless view rather than of the engine's frames, and it is a limit
// on what these tests can assert, not on the application.
@(private = "file")
preview_selection :: proc(app: ^App, selector: string) -> (text: string, ok: bool) {
	element := find(app, "#bml-page")
	if element == nil {
		return "", false
	}
	asset, aerr := sa.element_asset(element, "frame")
	if aerr != nil {
		return "", false
	}
	document, derr := sa.asset_get(asset, "document")
	defer sa.value_clear(&document)
	if derr != nil {
		return "", false
	}
	root, rerr := sa.element_from_value(&document)
	if rerr != nil {
		return "", false
	}
	found, ferr := sa.select_first(root, selector)
	if ferr != nil || found == nil {
		return "", false
	}
	value, terr := sa.text(found, context.temp_allocator)
	return value, terr == nil
}

// The mark names the script declares, read out of the composed document. Reading them rather than repeating
// them here is the point: a name added to the script with no stylesheet rule has to FAIL the test, and a
// list duplicated in this file would only ever test itself.
@(private = "file")
marks_declared_by_the_script :: proc(
	document: string,
	variable := "BML_MARKS",
	allocator := context.allocator,
) -> (
	names: []string,
	ok: bool,
) {
	opening := fmt.tprintf("var %s = [", variable)
	start := strings.index(document, opening)
	if start < 0 {
		return nil, false
	}
	rest := document[start:]
	close := strings.index(rest, "]")
	if close < 0 {
		return nil, false
	}
	list := make([dynamic]string, 0, 8, allocator)
	for field in strings.split(rest[len(opening):close], ",", context.temp_allocator) {
		name := strings.trim(field, " \t\r\n\"")
		if name != "" {
			append(&list, strings.clone(name, allocator))
		}
	}
	return list[:], len(list) > 0
}

// The widget's LINES are the buffer, and its `content` property is not. This is the measurement `bml_source`
// is built on, kept as a test because the whole save path depends on it and because it is the sort of thing
// a later engine could quietly fix — at which point this fails and says so, which is the useful outcome
// either way.
//
// Measured on Sciter 6.0.4.9: writing three lines gives three `<text>` children holding exactly those three
// lines, and a `content` that has gained a blank line at the FRONT and LOST the boundary between the last
// two. `\n` and `\r\n` are both accepted going in.
@(test)
test_the_widget_lines_are_the_buffer :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	for input in ([]string{"a\nb\nc", "a\r\nb\r\nc"}) {
		set_bml_source(&app, input)
		pump(&app)

		lines, ok := bml_source(&app, context.temp_allocator)
		testing.expect(t, ok, "the buffer could not be read")
		testing.expect_value(t, lines, "a\nb\nc")

		// And the property this does NOT use, so the reason is on the record rather than in a comment.
		element := find(&app, "#bml-text")
		asset, aerr := sa.element_asset(element, "plaintext")
		testing.expect_value(t, aerr, nil)
		value, gerr := sa.asset_get(asset, "content")
		defer sa.value_clear(&value)
		testing.expect_value(t, gerr, nil)
		content, serr := sa.value_to_string(&value, context.temp_allocator)
		testing.expect_value(t, serr, nil)
		testing.expect_value(t, content, "\r\na\r\nbc")
	}
}

// The editor's LAYOUT, as far as a windowless view can judge it — which is the geometry and not the look.
//
// What this catches is the failure this engine actually produces: an element with no size. `size: *` is how
// a Sciter box fills what is left, and the two halves of the split and the `<frame>` inside the right one
// each depend on it; get any of them wrong and the half is 0 wide (or the frame is), which reads as "the
// editor opened empty" or "preview did nothing" rather than as a stylesheet mistake. `frame#page` carries
// the same comment for the same reason.
//
// What it CANNOT judge is everything the colours and the proportions are about. That needs the window.
@(test)
test_the_editor_split_gives_both_halves_a_box :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)

	view, verr := sa.location(find(&app, "#editview"), .Border, .Root)
	testing.expect_value(t, verr, nil)
	source, serr := sa.location(find(&app, "#bml-text"), .Border, .Root)
	testing.expect_value(t, serr, nil)
	preview, perr := sa.location(find(&app, "#bml-page"), .Border, .Root)
	testing.expect_value(t, perr, nil)

	testing.expectf(t, view.width > 1000, "the editor should fill the window, not %dpx", view.width)
	testing.expectf(t, source.width > 300, "the source half is %dpx wide", source.width)
	testing.expectf(t, preview.width > 300, "the preview half is %dpx wide", preview.width)
	testing.expectf(t, source.height > 400, "the source half is %dpx tall", source.height)
	testing.expectf(t, preview.height > 400, "the preview half is %dpx tall", preview.height)

	// Halves, within a pixel or two of each other — the whole point of `width: *` on both.
	testing.expectf(
		t,
		abs(source.width - preview.width) <= 2,
		"the split is lopsided: %dpx of source against %dpx of preview",
		source.width,
		preview.width,
	)
	// Side by side rather than stacked, and both inside the view.
	testing.expect(t, source.x + source.width <= preview.x + 2, "the source half must be left of the preview")
	testing.expect(
		t,
		source.y >= view.y && preview.y + preview.height <= view.y + view.height,
		"both halves must be inside the view",
	)
}

// The stripper, on the shapes that were measured. This cannot assert the CRASH — a test that crashes takes
// the runner down with it — so it asserts the thing that prevents it, against exactly the conditions that
// were bisected: a width feature goes, a bare media type stays.
@(test)
test_width_media_blocks_are_stripped :: proc(t: ^testing.T) {
	css :=
		"body { background: antiquewhite; } " +
		"@media all and (max-width: 699px) { .content { max-width: 600px; } } " +
		".content { max-width: 900px; } " +
		"@media (max-width: 799px) { .content { max-width: 700px; } h1 { font-size: 2em; } } " +
		"@media all and (min-width: 900px) and (max-width: 1045px) { .content { max-width: 800px; } } " +
		"@media screen { .nav-links { display: block; } } " +
		"a { color: Sienna; } "

	out := strip_width_media_blocks(css, context.temp_allocator)
	testing.expect(t, !strings.contains(out, "max-width: 699px"), "a bare width feature must go")
	testing.expect(t, !strings.contains(out, "max-width: 799px"), "and so must the next one")
	testing.expect(t, !strings.contains(out, "min-width: 900px"), "and the min/max range")
	testing.expect(t, !strings.contains(out, "600px"), "the rules inside a dropped block go with it")
	testing.expect(t, !strings.contains(out, "font-size: 2em"), "every rule inside it, not just the first")

	testing.expect(t, strings.contains(out, "@media screen"), "a bare media TYPE is safe and must stay")
	testing.expect(t, strings.contains(out, ".nav-links"), "so must what is inside it")
	testing.expect(t, strings.contains(out, "background: antiquewhite"), "ordinary rules before a block stay")
	testing.expect(t, strings.contains(out, "max-width: 900px"), "the base width rule is the one that survives")
	testing.expect(t, strings.contains(out, "color: Sienna"), "and the rules after the last block")
}

// The notes' own stylesheet, through the stripper, is safe to hand this engine — and it is not a trivial
// pass: `bml.css` carries a dozen width blocks and they are what the preview would die on.
@(test)
test_the_real_stylesheet_survives_the_stripper :: proc(t: ^testing.T) {
	dir, note := bml_docs_dir(context.temp_allocator)
	if dir == "" {
		log.warnf("no corpus (%s) — skipping", note)
		return
	}
	path := filepath.join({dir, "bml.css"}, context.temp_allocator) or_else ""
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		log.warnf("no bml.css at %s (%v) — skipping", path, err)
		return
	}
	css := string(data)
	testing.expect(t, strings.contains(css, "max-width:"), "this test is pointless if the sheet has no width rules")

	out := strip_width_media_blocks(css, context.temp_allocator)
	testing.expect(t, len(out) < len(css), "something should have been removed")
	testing.expect(t, strings.contains(out, "background: antiquewhite"), "the page background must survive")
	// Not one `@media` left carrying a width feature — checked by walking what is left rather than by
	// trusting the count, because one missed block is a crash rather than a wrong colour.
	rest := out
	for {
		at := strings.index(rest, "@media")
		if at < 0 {
			break
		}
		open := strings.index_byte(rest[at:], "{"[0])
		testing.expect(t, open >= 0, "an @media with no block survived")
		if open < 0 {
			break
		}
		condition := rest[at:][:open]
		testing.expectf(t, !strings.contains(condition, "width"), "a width query survived: %q", condition)
		rest = rest[at + open + 1:]
	}
}

// Does the preview page FILL its half, or does it paint its background over the content column and leave
// white either side? That was the first thing wrong with it in the real window, and it is what
// `PREVIEW_OVERRIDE_CSS` exists for.
//
// THE PAGE IS LOADED AS THE VIEW'S OWN DOCUMENT, not into the `<frame>`, and that is forced rather than
// chosen: a hidden frame is 1x1 and everything inside it measures 0, while a frame that is both DISPLAYED
// and LOADED cannot be reached into at all from a windowless view without taking the process down (see
// `preview_selection`). Loading the page directly is the same harness `page_check` uses on the card page,
// and it measures the thing in question — a page of this shape, in a viewport of this size.
@(test)
test_the_preview_page_fills_the_view :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir, note := bml_docs_dir(context.temp_allocator)
	if dir == "" {
		log.warnf("no corpus (%s) — skipping", note)
		return
	}
	app.docs = dir

	source := strings.join(
		{"#+TITLE: filled", "", "* Opening bids", "", "1C = 16+ hcp, any shape", "  1D = 0-7 hcp"},
		"\n",
		context.temp_allocator,
	)
	doc := bml.parse(source, {resolve_include = bml_include, include_user = &app})
	defer bml.destroy(doc)
	page := preview_document(&app, bml.render_html(doc, context.temp_allocator), allocator = context.temp_allocator)
	testing.expect(t, strings.contains(page, "antiquewhite"), "the notes' stylesheet should be inlined")

	testing.expect_value(t, sa.load_html(g_view.window, page, "file://workbench/bml-preview.html"), nil)
	pump_view()

	root := sa.root(g_view.window) or_else nil
	testing.expect(t, root != nil, "the preview page has no root")
	if root == nil {
		return
	}

	view, verr := sa.location(root, .Border, .Root)
	testing.expect_value(t, verr, nil)

	body, berr := sa.select_first(root, "body")
	testing.expect_value(t, berr, nil)
	if berr != nil {
		return
	}
	box, lerr := sa.location(body, .Border, .Root)
	testing.expect_value(t, lerr, nil)

	// THE ROOT is the box that has to fill the view, because it is the one being painted — the body cannot
	// be, since in these pages the body IS the 900px content column (`<body class="content">`). Measured
	// here at 901 of 1121, which is exactly the white strip the window showed.
	testing.expectf(
		t,
		view.width >= 1118 && view.height >= 700,
		"the root is %dx%d — it does not fill the view, so painting it will not fill it either",
		view.width,
		view.height,
	)
	testing.expectf(t, box.width <= 902, "the content column is %dpx wide, past its max-width", box.width)
	testing.expectf(t, box.height >= 200, "the content column is only %dpx tall", box.height)

	// Centred, which is what leaves a gutter either side — the gutter this is all about.
	left := box.x - view.x
	right := (view.x + view.width) - (box.x + box.width)
	testing.expectf(t, left > 20 && right > 20, "no gutter to paint: %dpx left, %dpx right", left, right)
	testing.expectf(t, abs(left - right) <= 2, "the column is not centred: %dpx left against %dpx right", left, right)

	// And the gutter is PAINTED, in the colour the sheet gave the body. The computed value comes from the
	// page's own runtime because the host bindings read boxes, not styles — the same reason `dump_page`
	// measures the card page from inside it.
	painted, eerr := sa.eval(g_view.window, "String(getComputedStyle(document.documentElement).backgroundColor)")
	defer sa.value_clear(&painted)
	if eerr != nil {
		log.warnf("could not read the root's computed background (%v) — the geometry above still holds", eerr)
		return
	}
	colour, serr := sa.value_to_string(&painted, context.temp_allocator)
	testing.expect_value(t, serr, nil)
	// antiquewhite is 250,235,215. Whatever spelling the engine hands back, it must not be transparent and
	// must not be the default white — either of those is a white gutter.
	testing.expectf(t, colour != "", "the root has no computed background at all")
	testing.expectf(
		t,
		!strings.contains(colour, "transparent") && !strings.contains(colour, "255,255,255"),
		"the root's background is %q — the gutters will be white",
		colour,
	)
}

// The override, on the two shapes that matter, without an engine: the colour is MIRRORED from the sheet
// rather than written out, so a change to `bml.css` cannot leave the preview's gutters the wrong colour.
@(test)
test_the_preview_override_mirrors_the_page_background :: proc(t: ^testing.T) {
	mirrored := preview_override_css(
		"body { font-family: 'Open Sans'; background: antiquewhite; } .content { max-width: 900px; }",
		context.temp_allocator,
	)
	testing.expect(t, strings.contains(mirrored, "background: antiquewhite"), "the body colour must reach the root")
	testing.expect(t, strings.contains(mirrored, "html { size: *"), "and the root must fill the frame")

	// `background-color` counts as the same thing.
	spelled := preview_override_css("body { background-color: #fdf6e3; }", context.temp_allocator)
	testing.expect(t, strings.contains(spelled, "background: #fdf6e3"), "background-color must be read too")

	// A compound selector is NOT the body rule: `.content` is what carries the width in these sheets, and
	// reading a colour out of `body.content` would be reading the column's own background.
	compound := preview_override_css("body.content { background: pink; }", context.temp_allocator)
	testing.expect(t, !strings.contains(compound, "pink"), "a compound selector is not the body rule")

	// Nothing to mirror: fill the body instead, so its text at least has no white gutters beside it.
	plain := preview_override_css(".content { max-width: 900px; }", context.temp_allocator)
	testing.expect(t, strings.contains(plain, "max-width: none"), "with no page colour, the body fills instead")
}

// The header bar has to survive a NARROW window, and it gained a button this session (`bml`), which is
// exactly the kind of change that pushes the last control off the right edge. `header` is a horizontal flow
// with a `width: *` title in the middle, so the title is what should give — but nothing enforces that, and
// a bar whose buttons have walked off the edge is unusable rather than ugly: `about` carries the licence
// obligation and `close`/`bml` are how the views are reached at all.
//
// The view is RESIZED and put back, because `g_view` lives for the whole process and every later test would
// otherwise run in whatever size this one left behind.
@(test)
test_the_header_survives_a_narrow_window :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	NARROW_W :: 640
	NARROW_H :: 520
	defer {
		sa.resize_windowless(&g_view, 1120, 780)
		pump_view()
	}

	for size in ([][2]i32{{1120, 780}, {NARROW_W, NARROW_H}}) {
		testing.expect_value(t, sa.resize_windowless(&g_view, size[0], size[1]), nil)
		pump_view()

		root := sa.root(g_view.window) or_else nil
		if root == nil {
			continue
		}
		view, verr := sa.location(root, .Border, .Root)
		testing.expect_value(t, verr, nil)

		// Every control in the bar, and the bar itself. `#engine` is text rather than a control but it is
		// what was crowding the About button when the engine version used to live in it, so it is measured.
		for selector in ([]string{"header", "#tabs", "#engine", "#about", `.tab[data-view="editor"]`}) {
			element := find(&app, selector)
			testing.expectf(t, element != nil, "no %s", selector)
			if element == nil {
				continue
			}
			box, lerr := sa.location(element, .Border, .Root)
			testing.expect_value(t, lerr, nil)
			testing.expectf(
				t,
				box.x + box.width <= view.x + view.width,
				"at %dx%d, %s ends at %dpx in a %dpx window",
				size[0],
				size[1],
				selector,
				box.x + box.width,
				view.width,
			)
			testing.expectf(t, box.width > 0 && box.height > 0, "at %dx%d, %s has no box", size[0], size[1], selector)
		}

		// One row, not two: the buttons wrapping under the title is the failure this really guards, and it
		// shows up as a header taller than a line of text with its padding.
		header, herr := sa.location(find(&app, "header"), .Border, .Root)
		testing.expect_value(t, herr, nil)
		testing.expectf(
			t,
			header.height < 60,
			"at %dx%d the header is %dpx tall — its controls wrapped",
			size[0],
			size[1],
			header.height,
		)
	}
}

// The editor's own bar is the same shape and the same risk, and it carries more: a 260px picker, three
// buttons, the `?` and a `width: *` status line. Narrow enough and the status line is what should give.
@(test)
test_the_editor_bar_survives_a_narrow_window :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)

	defer {
		sa.resize_windowless(&g_view, 1120, 780)
		pump_view()
	}
	testing.expect_value(t, sa.resize_windowless(&g_view, 720, 520), nil)
	pump_view()

	root := sa.root(g_view.window) or_else nil
	if root == nil {
		return
	}
	view, _ := sa.location(root, .Border, .Root)

	for selector in ([]string {
			"#bml-files-toggle",
			"#bml-folder",
			"#bml-fold",
			"#bml-links",
			"#bml-preview",
			"#bml-save",
		}) {
		element := find(&app, selector)
		testing.expectf(t, element != nil, "no %s", selector)
		if element == nil {
			continue
		}
		box, _ := sa.location(element, .Border, .Root)
		testing.expectf(
			t,
			box.x + box.width <= view.x + view.width,
			"at 720px, %s ends at %dpx in a %dpx window",
			selector,
			box.x + box.width,
			view.width,
		)
	}
	bar, berr := sa.location(find(&app, ".bar"), .Border, .Root)
	testing.expect_value(t, berr, nil)
	testing.expectf(t, bar.height < 60, "at 720px the editor bar is %dpx tall — its controls wrapped", bar.height)
}

// ---- the tabs -----------------------------------------------------------------------------------
//
// The header is a PROJECTION of `View`, which is the whole reason there is no `close` anywhere: the strip
// says where you are, and clicking it says where to go. Three things can therefore go wrong silently and
// each has a check here — the strip disagreeing with what is on screen, a tab for a place that has nothing
// behind it being clickable, and About losing the place it was entered from.

// Clicking a tab navigates, and the strip agrees with the view afterwards.
@(test)
test_a_tab_selects_its_view :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_view(&app, .Panes)
	pump(&app)
	testing.expect(t, tab_is_selected(&app, "panes"), "the opening view should be marked at startup")

	click(&app, `.tab[data-view="editor"]`)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Editor)
	testing.expect(t, tab_is_selected(&app, "editor"), "the notes tab should be marked")
	testing.expect(t, !tab_is_selected(&app, "panes"), "and only one tab at a time")

	click(&app, `.tab[data-view="panes"]`)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Panes)
	testing.expect(t, tab_is_selected(&app, "panes"), "back to the deals tab")
}

// THE BAR`S BUTTONS ARE DEAD UNTIL THERE IS A PAGE, and the refusal is the MODEL`s. Worth asserting because
// the engine does not enforce it: `do_click` runs a disabled button`s behavior and the click is delivered
// like any other, so a check that only read the attribute would pass while the application opened an empty
// pane.
@(test)
test_the_hand_pane_button_is_dead_until_there_is_a_page :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)
	pump(&app)

	button := find(&app, "#deal-page")
	testing.expect(t, button != nil, "no hand-page button")
	if button == nil {return}
	state, _ := sa.element_state(button)
	testing.expect(t, .DISABLED in state, "the hand-page button should start disabled")

	click(&app, "#deal-page")
	pump(&app)
	testing.expect(t, !page_pane_shown(&app), "a click with nothing behind it must not open the pane")

	shown := show_page_html(&app, MINIMAL_PAGE, "a page")
	testing.expect(t, shown, "the page did not load into the frame")
	if !shown {return}
	pump(&app)
	testing.expect(t, page_pane_shown(&app), "the page opened the pane")
	state2, _ := sa.element_state(button)
	testing.expect(t, .DISABLED not_in state2, "a page unlocks the button")

	// And the pane is a TOGGLE from there: closed on the next press, open on the one after, with the page
	// still in it - closing must not need the page regenerating.
	click(&app, "#deal-page")
	pump(&app)
	testing.expect(t, !page_pane_shown(&app), "the second press closes it")
	click(&app, "#deal-page")
	pump(&app)
	testing.expect(t, page_pane_shown(&app), "and the third opens it again")
	title, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	testing.expect_value(t, title, "a page")
}

// About is the one thing with a `close`, because it is an errand rather than a place. Closing it goes back
// to WHERE IT WAS ENTERED FROM — dropping someone onto the panes would throw away a loaded card page or the
// chapter they were reading for no reason — and it leaves the tab strip saying where that is.
@(test)
test_about_returns_to_where_it_was_opened_from :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	show_editor(&app)
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Editor)

	click(&app, "#about")
	pump(&app)
	testing.expect_value(t, current_view(&app), View.About)
	// The strip still says where closing will land, which is the point of not re-marking it for About.
	testing.expect(t, tab_is_selected(&app, "editor"), "About should leave the tab strip alone")

	click(&app, "#about-close")
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Editor)
}

// A document that loads and lays out in a frame, and nothing more: these tests are about navigation, not
// about the card page (`page-check` owns that).
@(private = "file")
MINIMAL_PAGE :: "<html><head><style>body { size: *; }</style></head><body><h1>page</h1></body></html>"

// The `:disabled` STATE, not the attribute: a presence-only `disabled` in the markup reads back as an
// EMPTY attribute value, so `attribute(...) != ""` is false for a tab that really is disabled. The state
// bits are what the engine itself matches `:disabled` on, and they answer for both spellings.
@(private = "file")
tab_is_disabled :: proc(app: ^App, view: string) -> bool {
	element := find(app, fmt.tprintf(`.tab[data-view="%s"]`, view))
	if element == nil {
		return false
	}
	state, err := sa.element_state(element)
	return err == nil && .DISABLED in state
}

@(private = "file")
tab_is_selected :: proc(app: ^App, view: string) -> bool {
	element := find(app, fmt.tprintf(`.tab[data-view="%s"]`, view))
	if element == nil {
		return false
	}
	classes, err := sa.attribute(element, "class", context.temp_allocator)
	return err == nil && strings.contains(classes, "sel")
}

// A click, the way the engine delivers one. `do_click` is what the bindings offer for a button and it is
// what the window handler then sees — which is the seam these tests are about, so it is worth going through
// it rather than calling the handler's body.
@(private = "file")
click :: proc(app: ^App, selector: string) {
	element := find(app, selector)
	if element == nil {
		return
	}
	_, _ = sa.do_click(element)
}

// ---- the heading palette (CTRL+R) ----------------------------------------------------------------
//
// The ranking and the parsing are `outline`'s, tested there with no engine in the way. What is worth a
// document is the SEAM: that the key reaches the palette at all while a widget has the focus, that the
// keys the input's own edit behavior would otherwise eat (enter, escape, the arrows) get to the palette
// first, that a row is a real control, and — the one that would be a silent wrong answer rather than a
// visible failure — that the caret ends up on the row the heading is actually on.

// CTRL+R opens it, and the list opens on the file being edited. Through the window handler: a key test with
// nothing attached passes without an event being delivered.
@(test)
test_ctrl_r_opens_the_heading_palette_on_the_open_file :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)

	testing.expect(t, effective_display_is_hidden(&app, "#bml-goto"), "the palette starts closed")
	press_key(&app, .R, ctrl = true)
	pump(&app)

	testing.expect(t, app.goto_open, "CTRL+R should open the palette")
	testing.expect(t, !effective_display_is_hidden(&app, "#bml-goto"), "the palette should be on screen")
	testing.expect(t, len(app.goto_all) > 100, "the whole corpus's headings should be indexed, not one file's")

	rows := goto_row_elements(&app)
	testing.expect(t, len(rows) > 0, "an empty query still lists headings")
	testing.expect(t, len(rows) <= GOTO_ROWS, "the list is capped at GOTO_ROWS rows")
	// The open file first, which is the whole reason the palette is worth opening with nothing typed.
	testing.expect_value(t, app.goto_rows[0].file, app.bml_open)
	// And the highlight is on the first row, so ENTER means something the moment it is open.
	marked, merr := sa.select_all(find(&app, "#bml-goto-list"), ".hit.sel", context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, len(marked), 1)

	// The same key closes it.
	press_key(&app, .R, ctrl = true)
	pump(&app)
	testing.expect(t, !app.goto_open, "CTRL+R again should close it")
	testing.expect(t, effective_display_is_hidden(&app, "#bml-goto"), "and take it off screen")
}

// Typing filters, and ENTER jumps — to ANOTHER FILE, which is the case a file-list-then-scroll workflow
// cannot do at all. The destination is read out of the index, so the assertion is on the caret's row rather
// than on a heading name this test hard-codes.
@(test)
test_typing_a_heading_and_pressing_enter_jumps_to_it :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)
	press_key(&app, .R, ctrl = true)
	pump(&app)

	target, found := typeable_heading_elsewhere(&app)
	if !found {
		log.warn("no plainly-typeable heading in another chapter — skipping")
		return
	}
	type_query(&app, target.text)
	pump(&app)

	// An exact name is the top of the range in `outline.score_name`, so it is the highlighted row.
	testing.expect(t, len(app.goto_rows) > 0, "an exact heading name must match itself")
	testing.expect_value(t, app.goto_rows[0].text, target.text)
	testing.expect_value(t, app.goto_rows[0].file, target.file)

	press_key(&app, .ENTER)
	pump(&app)

	testing.expect(t, !app.goto_open, "a jump closes the palette")
	testing.expect_value(t, app.bml_open, target.file)
	testing.expect_value(t, caret_row(&app), target.row)
	// And the caret really is on that heading — the row is only a number until the line is read back.
	source, got := bml_source(&app, context.temp_allocator)
	testing.expect(t, got, "the file should be in the editor")
	lines := strings.split_lines(source, context.temp_allocator)
	if target.row < len(lines) {
		testing.expect(
			t,
			strings.contains(lines[target.row], target.text),
			fmt.tprintf("row %d of %s reads %q, not the heading", target.row, target.file, lines[target.row]),
		)
	}
}

// The arrows move the highlight and ESCAPE closes with the caret where it was. Both keys the input's own
// edit behavior would otherwise take, which is why the handler claims them on the way DOWN.
@(test)
test_the_arrows_choose_a_row_and_escape_closes_the_palette :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)
	press_key(&app, .R, ctrl = true)
	pump(&app)
	if len(app.goto_rows) < 3 {
		log.warn("fewer than three headings listed — skipping")
		return
	}

	press_key(&app, .DOWN)
	press_key(&app, .DOWN)
	pump(&app)
	testing.expect_value(t, app.goto_sel, 2)
	// The mark follows the model, or the row ENTER acts on is not the row anyone can see.
	marked, _ := sa.select_all(find(&app, "#bml-goto-list"), ".hit.sel", context.temp_allocator)
	testing.expect_value(t, len(marked), 1)
	index, _ := sa.attribute(marked[0], "data-goto", context.temp_allocator)
	testing.expect_value(t, index, "2")

	// Up past the top WRAPS to the end rather than sticking, so a held key never looks broken.
	press_key(&app, .UP)
	press_key(&app, .UP)
	press_key(&app, .UP)
	pump(&app)
	testing.expect_value(t, app.goto_sel, len(app.goto_rows) - 1)

	before := caret_row(&app)
	press_key(&app, .ESCAPE)
	pump(&app)
	testing.expect(t, !app.goto_open, "escape closes the palette")
	testing.expect(t, effective_display_is_hidden(&app, "#bml-goto"), "and takes it off screen")
	testing.expect_value(t, caret_row(&app), before) // a cancel moves nothing
}

// A row is a real control. Same lesson as the scenario rows and the file rows: a plain `<div>` raises no
// `.BUTTON_CLICK`, so the pointer would do nothing at all and only `do_click` catches it.
@(test)
test_clicking_a_palette_row_jumps_to_that_heading :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)
	press_key(&app, .R, ctrl = true)
	pump(&app)

	rows := goto_row_elements(&app)
	if len(rows) < 2 {
		log.warn("fewer than two headings listed — skipping")
		return
	}
	// The second row, so this cannot pass by accident on the one that was already highlighted.
	wanted := app.goto_rows[1]
	handled, cerr := sa.do_click(rows[1])
	testing.expect_value(t, cerr, nil)
	testing.expect(t, handled, "a palette row must answer a click (behavior: button)")
	pump(&app)

	testing.expect(t, !app.goto_open, "a click jumps and closes")
	testing.expect_value(t, app.bml_open, wanted.file)
	testing.expect_value(t, caret_row(&app), wanted.row)
}

// The palette belongs to the notes view: its keys are claimed while it is open, so leaving the view has to
// close it or ESCAPE and the arrows stay captured behind another tab.
@(test)
test_leaving_the_notes_view_closes_the_palette :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)
	press_key(&app, .R, ctrl = true)
	pump(&app)
	testing.expect(t, app.goto_open, "the palette should be open")

	click(&app, `.tab[data-view="panes"]`)
	pump(&app)
	testing.expect(t, !app.goto_open, "switching view closes the palette")

	// And the key is nobody's outside the notes view.
	press_key(&app, .R, ctrl = true)
	pump(&app)
	testing.expect(t, !app.goto_open, "CTRL+R does nothing on the deals view")
}

// The index is built from the BUFFER for the file being edited, so a heading typed a moment ago is already a
// destination. This is the test that fails if the index is ever read from disk for the open file, or cached
// across an edit.
@(test)
test_the_palette_finds_a_heading_that_is_only_in_the_buffer :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	app.docs = ""

	// No folder, no files — the palette has nothing to index and says so rather than opening empty.
	show_editor(&app)
	pump(&app)
	press_key(&app, .R, ctrl = true)
	pump(&app)
	testing.expect(t, !app.goto_open, "with no folder there is nothing to go to")

	// A folder of one file, whose buffer holds a heading the FILE does not.
	dir := scratch_bml_dir(t)
	if dir == "" {return}
	defer os.remove(dir) // an empty directory; `remove` takes either on this platform
	name := "wb-goto-buffer.bml"
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("* On disk\n\n1C = strong\n")), nil)
	defer os.remove(path)

	use_bml_dir(&app, dir)
	// `use_bml_dir` frees what it replaces, so what it leaves behind is this test's to free -
	// `test_app_destroy` cannot, since other tests hand the same fields TEMP memory.
	defer {
		for listed in app.bml_names {
			delete(listed, app.allocator)
		}
		delete(app.bml_names, app.allocator)
		delete(app.docs, app.allocator)
		app.bml_names = nil
		app.docs = ""
	}
	pump(&app)
	testing.expect_value(t, app.bml_open, name)
	set_bml_source(&app, "* On disk\n\n1C = strong\n\n** Typed just now\n")
	pump(&app)

	press_key(&app, .R, ctrl = true)
	pump(&app)
	testing.expect(t, app.goto_open, "the palette should open on a folder with headings in it")
	type_query(&app, "Typed just now")
	pump(&app)
	testing.expect(t, len(app.goto_rows) > 0, "a heading in the buffer is a destination")
	testing.expect_value(t, app.goto_rows[0].text, "Typed just now")
	press_key(&app, .ENTER)
	pump(&app)
	testing.expect_value(t, caret_row(&app), 4)
}

// A document the parser OBJECTS to still gets previewed, pane and all. This was broken and is exactly the
// kind of thing a hand test misses: most chapters are clean, so the pane appeared, and one mistyped
// directive was enough to render into a frame that was never shown - which reads as "preview does nothing on
// this file" rather than as a diagnostic.
@(test)
test_a_document_with_a_diagnostic_still_shows_the_preview_pane :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	set_bml_source(&app, "#NOTADIRECTIVE oops\n\n* One\n\n1C = strong\n")
	app.bml_open = strings.clone("scratch.bml", app.allocator)
	pump(&app)

	rendered, why := preview_bml(&app)
	testing.expectf(t, rendered, "a document with a diagnostic still renders: %s", why)
	testing.expect(t, app.bml_showing, "the pane has to be up, diagnostic or not")
	testing.expect(t, !effective_display_is_hidden(&app, "#bml-page"), "the frame must be on screen")
	// And the diagnostic is still what the status line reports, since that is the useful half.
	testing.expect(t, len(why) > 0 && strings.contains(why, "marked"), fmt.tprintf("no diagnostic reported: %q", why))
}

// The PREVIEW half of the same scroll: the heading has to be FINDABLE in the rendered page, which is the
// part that can be wrong quietly — the host matches headings by their text, so a renderer that wrapped a
// heading's text in a span, or a trailing space, would silently stop the preview following the jump.
//
// The movement itself is not asserted, and cannot be here: `scroll_to_view` does nothing until the window
// has been shown and rendered (the bindings say so), and a windowless view must not reach into a DISPLAYED
// frame at all (see `preview_selection`) — so this previews into a HIDDEN frame, as the other preview tests
// do, and asserts the lookup.
@(test)
test_the_preview_can_find_the_heading_a_jump_landed_on :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	source := "* One\n\n1C = strong\n\n* Two Deep\n\n2C = weak\n\n*** Three\n\n3C = preempt\n"
	set_bml_source(&app, source)
	app.bml_open = strings.clone("scratch.bml", app.allocator)
	pump(&app)

	rendered, why := preview_bml(&app)
	testing.expectf(t, rendered, "the preview did not render: %s", why)
	pump(&app)

	// Every level the palette can jump to, including the `***` one that is not a top-level section.
	for name in ([]string{"One", "Two Deep", "Three"}) {
		testing.expectf(t, scroll_preview_to_heading(&app, name), "the preview should hold the heading %q", name)
	}
	// And a heading that is not there is reported rather than scrolling to something else.
	testing.expect(t, !scroll_preview_to_heading(&app, "Not A Heading Here"), "a missing heading is not found")
}

// THE CASE THAT MADE THE PREVIEW SCROLL LOOK COMPLETELY BROKEN, and the reason the lookup is by anchor id: a
// heading is BML, so `1!c-1!s` renders as `1<span class="ccolor">♣</span>-1<span class="scolor">♠</span>` and
// a heading holding a cross-reference renders an `<a>` inside it. Neither reads back as the typed string, so
// a text match found nothing — silently, on most of this corpus, since so many headings name a suit.
@(test)
test_the_preview_finds_a_heading_that_renders_as_markup :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	source := "* 1!c opening\n\n1C = strong\n\n** 1!c-1!s Compromise\n\n2N = balanced\n\n*** After a [double](#Takeout)\n"
	set_bml_source(&app, source)
	app.bml_open = strings.clone("scratch.bml", app.allocator)
	pump(&app)
	rendered, why := preview_bml(&app)
	testing.expectf(t, rendered, "the preview did not render: %s", why)
	pump(&app)

	// Exactly the strings the palette holds — the SOURCE text of each heading, macros and link markup and all.
	for name in ([]string{"1!c opening", "1!c-1!s Compromise", "After a [double](#Takeout)"}) {
		testing.expectf(
			t,
			scroll_preview_to_heading(&app, name),
			"the preview should find %q by its anchor id (%s)",
			name,
			bml.normalise_header_id(name, context.temp_allocator),
		)
	}
	// A near miss is still a miss: the id is the whole string, not a prefix of it.
	testing.expect(t, !scroll_preview_to_heading(&app, "1!c"), "a partial heading is not a heading")
}

// THE SCROLL, which is the half that made the jump look like it had done nothing: `selectRange` moves the
// caret and leaves the view where it was, so a heading 1700 lines down was selected off screen. Read from
// the widget's own scroll position, which is what a person would be looking at.
@(test)
test_a_jump_scrolls_the_source_to_the_heading :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)
	app.docs = ""

	// A file long enough to have somewhere to scroll TO: 400 lines of prose with a heading near the end.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "* The top of the file\n")
	for i in 0 ..< 400 {
		fmt.sbprintf(&b, "%dC = a bid on line %d\n", 1 + i % 7, i)
	}
	strings.write_string(&b, "*** A long way down\n\n2N = and its table\n")
	set_bml_source(&app, strings.to_string(b))
	app.bml_open = strings.clone("scratch.bml", app.allocator)
	show_editor(&app)
	pump(&app)

	source, _ := bml_source(&app, context.temp_allocator)
	target := 0
	for line, row in strings.split_lines(source, context.temp_allocator) {
		if strings.contains(line, "A long way down") {
			target = row
		}
	}
	testing.expect(t, target > 200, "the heading should be a long way down the file")

	before, berr := sa.scroll_info(find(&app, "#bml-text"))
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, before.pos.y, 0)

	set_caret_row(&app, target)
	pump(&app)

	testing.expect_value(t, caret_row(&app), target)
	after, aerr := sa.scroll_info(find(&app, "#bml-text"))
	testing.expect_value(t, aerr, nil)
	testing.expectf(t, after.pos.y > 0, "the source pane did not scroll (still at %d)", after.pos.y)

	// The line is IN the view, and not at the very top of it: the lead-in is what tells you the heading is
	// in the middle of a document rather than at the start of one.
	line, cerr := sa.child(find(&app, "#bml-text"), sa.Child_Index(target))
	testing.expect_value(t, cerr, nil)
	box, lerr := sa.location(line, .Border, .Container)
	testing.expect_value(t, lerr, nil)
	testing.expectf(
		t,
		box.y >= after.pos.y && box.y + box.height <= after.pos.y + after.view.height,
		"line %d (at %d) is outside the view (%d..%d)",
		target,
		box.y,
		after.pos.y,
		after.pos.y + after.view.height,
	)
	testing.expectf(t, box.y - after.pos.y > 0, "there should be lead-in above the heading")
}

// The palette is a row of the editor's FLOW, not an overlay, and the reason is in the CSS header: an
// out-of-flow percentage height lays out 1px tall in this engine. So both halves have to keep their boxes
// while it is open - a palette that took the whole window, or one that laid out 1px tall, are the two ways
// this goes wrong and neither would fail any of the tests above.
@(test)
test_the_open_palette_leaves_both_editor_panes_a_box :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	attach_for_test(&app)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)
	press_key(&app, .R, ctrl = true)
	pump(&app)

	for selector in ([]string{"#bml-goto", "#bml-goto-input", "#bml-goto-list", "#bml-text", ".split"}) {
		element := find(&app, selector)
		testing.expectf(t, element != nil, "no %s", selector)
		if element == nil {
			continue
		}
		box, err := sa.location(element, .Border, .Root)
		testing.expect_value(t, err, nil)
		testing.expectf(t, box.width > 100 && box.height > 4, "%s has no box: %dx%d", selector, box.width, box.height)
	}

	// The palette is a BAR: a few rows of a 780px window, not most of it. The cap is `max-height` on the
	// list, and a cap that stopped applying would be invisible until the source had nowhere to go.
	palette, _ := sa.location(find(&app, "#bml-goto"), .Border, .Root)
	source, _ := sa.location(find(&app, "#bml-text"), .Border, .Root)
	testing.expectf(
		t,
		palette.height < 340,
		"the palette is %dpx tall — the row cap stopped applying",
		palette.height,
	)
	testing.expectf(t, source.height > 200, "the source is only %dpx tall with the palette open", source.height)
}

// ---- the palette's test plumbing ----------------------------------------------------------------

// The window handler, attached the way `main` attaches it. Every palette test needs it: the keys and the
// row clicks both arrive through it, and without it a key test passes vacuously.
@(private = "file")
attach_for_test :: proc(app: ^App) {
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = app,
	}
	sa.attach_window_handler(app.window, &app.handler)
}

// A key press at the document ROOT, which is where a window handler hears it from whatever has the focus.
@(private = "file")
press_key :: proc(app: ^App, key: sciter.Sc_Kb_Codes, ctrl := false) {
	root := sa.root(app.window) or_else nil
	if root == nil {
		return
	}
	_, _ = sa.send_key(root, .DOWN, u32(key), ctrl ? sciter.Keyboard_States{.LCONTROL} : {})
}

// Type into the query box the way a person would — one character at a time, so the edit behavior raises the
// `.VALUE_CHANGED` the list is redrawn from. Setting the value directly would test the redraw and not the
// wiring.
@(private = "file")
type_query :: proc(app: ^App, text: string) {
	input := find(app, "#bml-goto-input")
	if input == nil {
		return
	}
	_ = sa.set_focus(input)
	_ = sa.send_text(input, text)
	pump(app)
}

@(private = "file")
goto_row_elements :: proc(app: ^App) -> []sa.Element {
	rows, err := sa.select_all(find(app, "#bml-goto-list"), ".hit", context.temp_allocator)
	if err != nil {
		return nil
	}
	return rows
}

// A heading in a DIFFERENT chapter whose name can be typed literally: no `!c` suit macro, no punctuation the
// edit behavior might treat as a shortcut. The corpus has hundreds, so this is a filter and not a search.
@(private = "file")
typeable_heading_elsewhere :: proc(app: ^App) -> (heading: outline.Heading, ok: bool) {
	for entry in app.goto_all {
		if entry.file == app.bml_open || len(entry.text) < 6 || len(entry.text) > 40 {
			continue
		}
		plain := true
		for r in entry.text {
			if !(r == ' ' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')) {
				plain = false
				break
			}
		}
		if !plain {
			continue
		}
		// Unique in the corpus, or the ranking's tie-break is what this test would be asserting.
		seen := 0
		for other in app.goto_all {
			if other.text == entry.text {
				seen += 1
			}
		}
		if seen == 1 {
			return entry, true
		}
	}
	return {}, false
}

// A directory of our own to point the editor at. The user's notes are not a scratch space, and this test
// writes.
@(private = "file")
scratch_bml_dir :: proc(t: ^testing.T) -> string {
	dir, jerr := filepath.join({os.get_env("TEMP", context.temp_allocator), "wb-goto-scratch"}, context.temp_allocator)
	if jerr != nil {
		log.warn("no scratch directory available — skipping")
		return ""
	}
	if err := os.make_directory(dir); err != nil && !os.exists(dir) {
		log.warnf("could not make %s (%v) — skipping", dir, err)
		return ""
	}
	return strings.clone(dir, context.temp_allocator)
}

// ---- the file sidebar ---------------------------------------------------------------------------
//
// The list is the picker now, so three things it does are worth pinning: a row has to be CLICKABLE at all
// (`behavior: button` — the bug the scenario rows already taught this codebase), the list has to fold away,
// and pointing the editor at another folder has to replace the list rather than accumulate it.

// A row is a real control and a click on it opens the file. `do_click` goes through the same native
// controller a pointer does, which is why it catches a missing `behavior: button` where calling the handler
// directly would not.
@(test)
test_clicking_a_file_row_opens_it :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)

	rows, rerr := sa.select_all(find(&app, "#bml-list"), ".row", context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, len(rows), len(app.bml_names))
	if len(rows) < 2 {
		log.warn("fewer than two .bml files — nothing to click; skipping")
		return
	}

	// The second row, so this cannot pass by accident on the file `show_editor` opens by itself.
	wanted, _ := sa.attribute(rows[1], "data-file", context.temp_allocator)
	name := strings.clone(wanted, context.temp_allocator)
	handled, cerr := sa.do_click(rows[1])
	testing.expect_value(t, cerr, nil)
	testing.expect(t, handled, "a file row must answer a click (behavior: button)")
	pump(&app)

	testing.expect_value(t, app.bml_open, name)
	source, got := bml_source(&app, context.temp_allocator)
	testing.expect(t, got && len(source) > 0, "the file's text should be in the editor")

	// Exactly one row marked, and it is that one — the list is a projection of `bml_open`, so two marks
	// would mean two sources of truth.
	marked, merr := sa.select_all(find(&app, "#bml-list"), ".row.sel", context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, len(marked), 1)
	open_name, _ := sa.attribute(marked[0], "data-file", context.temp_allocator)
	testing.expect_value(t, open_name, name)
}

// The toggle folds the list away and brings it back, and the two panes take the room. Read from the document
// both times, because that is what the toggle itself reads — a remembered flag could disagree with it.
@(test)
test_the_files_toggle_folds_the_sidebar :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	if !editor_corpus(t, &app) {return}
	show_editor(&app)
	pump(&app)

	testing.expect(t, !effective_display_is_hidden(&app, "#bml-files"), "the list starts on screen")
	wide, _ := sa.location(find(&app, "#bml-text"), .Border, .Root)

	sa.do_click(find(&app, "#bml-files-toggle"))
	pump(&app)
	testing.expect(t, effective_display_is_hidden(&app, "#bml-files"), "the list should fold away")
	folded, _ := sa.location(find(&app, "#bml-text"), .Border, .Root)
	testing.expectf(
		t,
		folded.width > wide.width,
		"the source pane did not take the room: %dpx with the list, %dpx without",
		wide.width,
		folded.width,
	)

	sa.do_click(find(&app, "#bml-files-toggle"))
	pump(&app)
	testing.expect(t, !effective_display_is_hidden(&app, "#bml-files"), "and come back")
}

// Pointing the editor at another folder REPLACES what it was showing. This is the half of the folder dialog
// that can be tested: the dialog itself blocks in native modal code, so `choose_bml_folder` stops at the
// `Window.this.selectFolder` call and everything after it lives here.
@(test)
test_choosing_a_folder_replaces_the_list :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	if !editor_corpus(t, &app) {return}
	// `editor_corpus` hands out temp-allocated names; `use_bml_dir` frees what it replaces with the app's
	// allocator, so this test owns its own copies from the start.
	app.docs = strings.clone(app.docs, app.allocator)
	app.bml_names = clone_strings(app.bml_names, app.allocator)
	// `use_bml_dir` frees what it replaces, so whatever it leaves behind at the end is this test's to free —
	// `test_app_destroy` cannot, since other tests hand the same fields TEMP memory.
	defer {
		for name in app.bml_names {
			delete(name, app.allocator)
		}
		delete(app.bml_names, app.allocator)
		delete(app.docs, app.allocator)
	}
	show_editor(&app)
	pump(&app)
	testing.expect(t, len(app.bml_names) > 1, "the corpus should have more than one file")

	// A folder of our own with one file in it.
	dir := filepath.join({"target", "debug", "wb-editor-folder"}, context.temp_allocator) or_else "."
	if err := os.make_directory_all(dir); err != nil {
		log.warnf("could not create %s (%v) — skipping", dir, err)
		return
	}
	name := "only.bml"
	path := filepath.join({dir, name}, context.temp_allocator) or_else name
	if err := os.write_entire_file(path, transmute([]u8)string("#+TITLE: only\r\n")); err != nil {
		log.warnf("could not write %s (%v) — skipping", path, err)
		return
	}
	defer os.remove(path)

	use_bml_dir(&app, dir)
	pump(&app)

	testing.expect_value(t, len(app.bml_names), 1)
	testing.expect_value(t, app.bml_open, name) // the one file is opened for you
	testing.expect_value(t, app.docs, dir)

	rows, _ := sa.select_all(find(&app, "#bml-list"), ".row", context.temp_allocator)
	testing.expect_value(t, len(rows), 1) // replaced, not appended to
	shown, _ := sa.attribute(rows[0], "data-file", context.temp_allocator)
	testing.expect_value(t, shown, name)

	folder, ferr := sa.text(find(&app, "#bml-dir"), context.temp_allocator)
	testing.expect_value(t, ferr, nil)
	testing.expect(t, strings.contains(folder, "wb-editor-folder"), "the folder should be named above its files")

	// A folder with no notes in it is reported and KEPT, rather than refused: "did it not work, or is it
	// empty?" is a question the window should answer by itself.
	empty := filepath.join({"target", "debug", "wb-editor-empty"}, context.temp_allocator) or_else "."
	if err := os.make_directory_all(empty); err == nil {
		use_bml_dir(&app, empty)
		pump(&app)
		testing.expect_value(t, len(app.bml_names), 0)
		testing.expect_value(t, app.bml_open, "")
		none, _ := sa.select_all(find(&app, "#bml-list"), ".row", context.temp_allocator)
		testing.expect_value(t, len(none), 0)
	}
}

// With no folder found at startup the editor still OPENS, and says what to do. It used to refuse and name an
// environment variable, which is no use to somebody holding a mouse — the `folder…` button is the answer and
// it is in the view being refused.
@(test)
test_the_editor_opens_without_a_corpus :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.docs = ""
	app.bml_names = nil
	show_editor(&app)
	pump(&app)

	testing.expect_value(t, current_view(&app), View.Editor)
	testing.expect(t, find(&app, "#bml-folder") != nil, "the way out has to be in the view")
	status, _ := sa.text(find(&app, "#bml-status"), context.temp_allocator)
	testing.expect(t, strings.contains(status, "folder"), "it should say to choose a folder, not name a variable")
}

// A PREVIEW ON SCREEN FOLLOWS THE BUFFER. Clicking another file used to leave the old file rendered beside
// the new source, with nothing in the window to say so — the worst kind of wrong, because it looks right.
//
// Read through the frame's own document, hidden (see `preview_selection`), and asserted on the HEADING,
// which is the one thing that differs per file and is not in the source pane at all.
@(test)
test_a_preview_follows_the_file_that_is_open :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir := filepath.join({"target", "debug", "wb-editor-follow"}, context.temp_allocator) or_else "."
	if err := os.make_directory_all(dir); err != nil {
		log.warnf("could not create %s (%v) - skipping", dir, err)
		return
	}
	first, second := "aaa-first.bml", "zzz-second.bml"
	// The cleanup is deferred OUT HERE rather than inside the loop: a `defer` in a loop body runs at the end
	// of each ITERATION, so `defer os.remove(path)` there deleted each file the moment it was written and
	// left the list empty — which read as `list_bml_files` being broken.
	defer for name in ([]string{first, second}) {
		if path := filepath.join({dir, name}, context.temp_allocator) or_else ""; path != "" {
			os.remove(path)
		}
	}
	for pair in ([][2]string{{first, "Opening bids"}, {second, "Slam bidding"}}) {
		path := filepath.join({dir, pair[0]}, context.temp_allocator) or_else pair[0]
		text := strings.concatenate(
			{"#+TITLE: t\r\n\r\n* ", pair[1], "\r\n\r\n1C = 16+ hcp\r\n"},
			context.temp_allocator,
		)
		if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
			log.warnf("could not write %s (%v) - skipping", path, err)
			return
		}
	}

	app.docs = strings.clone(dir, app.allocator)
	app.bml_names = list_bml_files(dir, app.allocator)
	defer {
		for name in app.bml_names {
			delete(name, app.allocator)
		}
		delete(app.bml_names, app.allocator)
		delete(app.docs, app.allocator)
	}
	testing.expect_value(t, len(app.bml_names), 2)

	// NOT shown: `show_editor` would display the frame, and a displayed frame cannot be read into from a
	// windowless view at all. The buffer and the preview do not care which view is on screen.
	draw_bml_files(&app)
	ok, why := open_bml(&app, first)
	testing.expectf(t, ok, "could not open %s: %s", first, why)
	pump(&app)

	// No preview asked for yet, so opening a file must not render one — the first is something you ask for.
	testing.expect(t, !app.previewed, "opening a file should not preview it by itself")

	rendered, reason := preview_bml(&app)
	testing.expectf(t, rendered, "the preview did not render: %s", reason)
	pump(&app)
	testing.expect(t, app.previewed, "a rendered preview should be remembered")
	heading, found := preview_selection(&app, "h1")
	testing.expect(t, found, "the preview has no heading")
	testing.expect_value(t, heading, "Opening bids")

	// The bug: click the other file, and the preview must move with it.
	switch_bml_file(&app, second)
	pump(&app)
	testing.expect_value(t, app.bml_open, second)
	moved, still_there := preview_selection(&app, "h1")
	testing.expect(t, still_there, "the preview vanished when the file changed")
	testing.expect_value(t, moved, "Slam bidding")

	// And a new FOLDER forgets the preview: what is in the frame belongs to the folder just left, so the
	// next file opened there should not silently re-render into it.
	use_bml_dir(&app, dir)
	testing.expect(t, !app.previewed, "a folder change should forget the preview")
}

// ---- the squiggles ------------------------------------------------------------------------------
//
// The parse's diagnostics, marked on the text they are about. Same seam as the colour and the same
// problem: the marking happens in the document through an API this side cannot read back, so the script
// reports a COUNT and answers `bmlProblemAt` for the message. What these tests can and cannot see:
//   * the count, and the message at a position - both from the script;
//   * NOT the hover itself. `rangeFromPoint` needs a box, and in a windowless view the editor is inside a
//     hidden view, so every line measures 0x0 (measured). The hover's two halves are tested separately: the
//     lookup here, and the mark under the pointer by `page-check`'s cousin - the real window.

// The number of problems the document is currently holding, straight from the script.
@(private = "file")
problem_count :: proc(app: ^App) -> int {
	result, err := sa.eval(app.window, "bmlProblems.length")
	defer sa.value_clear(&result)
	if err != nil {
		return -1
	}
	count, ierr := sa.value_to_int(&result)
	return ierr == nil ? int(count) : -1
}

// What the hover would say at that line and column.
@(private = "file")
problem_at :: proc(app: ^App, line, col: int) -> string {
	script := fmt.tprintf("bmlProblemAt(%d, %d)", line, col)
	result, err := sa.eval(app.window, script)
	defer sa.value_clear(&result)
	if err != nil {
		return ""
	}
	text, terr := sa.value_to_string(&result, context.temp_allocator)
	return terr == nil ? text : ""
}

// A misspelled directive is the diagnostic that matters most, because without it the whole block is dropped
// from the page in silence. It has to arrive at the right line, and be readable there.
@(test)
test_a_bad_directive_is_squiggled_where_it_is :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = "" // no corpus needed: the buffer is written directly

	set_bml_source(&app, "* Openings\n\n1C = strong\n\n  #HDIE\n  1D = negative\n")
	pump(&app)
	rendered, why := preview_bml(&app)
	testing.expectf(t, rendered, "the preview did not render: %s", why)

	testing.expect_value(t, problem_count(&app), 1)
	// Line 5, column 3 — the `#` of `#HDIE`, two spaces in.
	message := problem_at(&app, 5, 3)
	testing.expectf(t, strings.contains(message, "#HDIE"), "the message does not name the directive: %q", message)
	testing.expect_value(t, problem_at(&app, 3, 1), "") // and nothing on the good line
	testing.expectf(t, strings.contains(why, "1 marked"), "the status should say what was marked: %q", why)
}

// The cross-reference check is OFF by default and the button turns it on, because a chapter of this corpus
// links to headings in its sibling files on purpose. Both states are the point.
@(test)
test_the_links_toggle_decides_whether_anchors_are_checked :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	// A click test needs the window handler ATTACHED, or every "nothing happened" passes vacuously.
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	set_bml_source(&app, "* Real Heading\n\nsee [elsewhere](#No Such Heading)\n")
	pump(&app)
	rendered, _ := preview_bml(&app)
	testing.expect(t, rendered, "the preview did not render")
	testing.expect_value(t, problem_count(&app), 0)

	// The button, not the flag: the click path is what a person has.
	click(&app, "#bml-links")
	pump(&app)
	testing.expect(t, app.bml_links, "the click should turn the check on")
	testing.expect_value(t, problem_count(&app), 1)
	message := problem_at(&app, 3, 17)
	testing.expectf(t, strings.contains(message, "anchor"), "the message should name the anchor: %q", message)

	// And off again, with the squiggle going away rather than being left behind.
	click(&app, "#bml-links")
	pump(&app)
	testing.expect(t, !app.bml_links, "the second click should turn the check off")
	testing.expect_value(t, problem_count(&app), 0)
}

// A diagnostic about an INCLUDED file has no line in this buffer, so marking it would put a squiggle on
// whatever happens to be at that line number. It is reported in the transcript instead.
@(test)
test_a_problem_in_another_file_is_reported_but_not_marked :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = "" // so the include cannot be resolved from anywhere

	set_bml_source(&app, "* Openings\n\n#INCLUDE nowhere.bml\n")
	pump(&app)
	rendered, _ := preview_bml(&app)
	testing.expect(t, rendered, "the preview did not render")

	// The include's own line IS in this buffer, so that one is marked.
	testing.expect_value(t, problem_count(&app), 1)
	testing.expect(
		t,
		strings.contains(strings.to_string(app.transcript), "nowhere.bml"),
		"the transcript should name the file that could not be read",
	)
}

// A squiggle is a position, and a position is only true of the text it was computed from. Opening another
// file has to take the marks with it - the alternative is a confident underline on an innocent word.
@(test)
test_a_squiggle_does_not_survive_the_buffer_it_was_computed_from :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	dir, jerr := filepath.join({os.get_env("TEMP", context.temp_allocator), "wb-squiggle"}, context.temp_allocator)
	testing.expect_value(t, jerr, nil)
	os.make_directory(dir)
	name := "one.bml"
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("* One\n\n1C = strong\n")), nil)
	defer os.remove(path)

	app.docs = "" // the bad text is written straight into the widget
	set_bml_source(&app, "#HDIE\n1C = strong\n")
	pump(&app)
	rendered, _ := preview_bml(&app)
	testing.expect(t, rendered, "the preview did not render")
	testing.expect_value(t, problem_count(&app), 1)

	// Now open a real file over it.
	use_bml_dir(&app, dir)
	pump(&app)
	opened, why := open_bml(&app, name)
	testing.expectf(t, opened, "the file did not open: %s", why)
	pump(&app)
	testing.expect_value(t, problem_count(&app), 0)
}

// ---- the global zoom ----------------------------------------------------------------------------
//
// CTRL+wheel, CTRL+plus/minus, CTRL+0. Split across the two languages for a measured reason (a wheel's
// delta reaches no host handler), so what is tested here is the seam: the script's clamp and round trip,
// the KEY path through the real window handler, and that the property really changes a box. The physical
// wheel is the one part no test can drive — it has no host-side entry point to synthesise.

// The width of a control, as the engine laid it out. The measurement zoom is supposed to move.
@(private = "file")
button_width :: proc(app: ^App, selector: string) -> i32 {
	element := find(app, selector)
	if element == nil {
		return 0
	}
	box, err := sa.location(element, .Border, .Root)
	return err == nil ? box.width : 0
}

@(test)
test_zoom_scales_the_window_and_comes_back :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// Not a silent skip: if this button has no box the test would "pass" having measured nothing.
	base := button_width(&app, "#generate")
	if !testing.expect(t, base > 0, "the generate button has no box to measure") {
		return
	}
	testing.expect_value(t, zoom_factor(&app), 1)

	// Four notches in is 1.1^4 ≈ 1.46, and the box has to move with it: `zoom` is a LAYOUT property in
	// this engine, which is the fact the whole feature rests on.
	for _ in 0 ..< 4 {
		zoom_step(&app, 1)
	}
	pump(&app)
	factor := zoom_factor(&app)
	testing.expectf(t, factor > 1.4 && factor < 1.5, "four notches in should be about 1.46, not %v", factor)
	wide := button_width(&app, "#generate")
	testing.expectf(t, wide > base, "the button is %dpx at %v zoom, was %dpx at 1", wide, factor, base)

	// CTRL+0 is a return to exactly 1, not to approximately 1 — the steps are multiplicative.
	zoom_step(&app, 0)
	pump(&app)
	testing.expect_value(t, zoom_factor(&app), 1)
	testing.expect_value(t, button_width(&app, "#generate"), base)
}

@(test)
test_zoom_stops_at_its_limits :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	// Far past either end, in one direction and then the other. A clamp that let the factor run would
	// leave a window nobody can read and no way back to it with the pointer.
	for _ in 0 ..< 40 {
		zoom_step(&app, 1)
	}
	high := zoom_factor(&app)
	testing.expectf(t, high <= 2.5 && high >= 2.2, "the top of the range should be about 2.5, not %v", high)

	for _ in 0 ..< 40 {
		zoom_step(&app, -1)
	}
	low := zoom_factor(&app)
	testing.expectf(t, low >= 0.7 && low <= 0.8, "the bottom of the range should be about 0.7, not %v", low)

	zoom_step(&app, 0)
	testing.expect_value(t, zoom_factor(&app), 1)
}

// The keyboard half, through the window handler the application installs — a key test with nothing attached
// would pass without a single event being delivered.
@(test)
test_ctrl_plus_and_minus_and_zero_are_the_zoom_keys :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	root := sa.root(app.window) or_else nil
	press :: proc(root: sa.Element, key: sciter.Sc_Kb_Codes, ctrl: bool) {
		_, _ = sa.send_key(root, .DOWN, u32(key), ctrl ? sciter.Keyboard_States{.LCONTROL} : {})
	}

	press(root, .EQUAL, true)
	testing.expectf(t, zoom_factor(&app) > 1, "CTRL+= should zoom in, factor is %v", zoom_factor(&app))
	press(root, .MINUS, true)
	testing.expect_value(t, zoom_factor(&app), 1)

	press(root, .KP_ADD, true)
	press(root, .KP_ADD, true)
	testing.expectf(t, zoom_factor(&app) > 1.2, "the numpad should zoom too, factor is %v", zoom_factor(&app))
	press(root, .NUM_0, true)
	testing.expect_value(t, zoom_factor(&app), 1)

	// WITHOUT ctrl, none of these are zoom keys — `-` and `0` are characters somebody is typing.
	press(root, .MINUS, false)
	press(root, .NUM_0, false)
	press(root, .EQUAL, false)
	testing.expect_value(t, zoom_factor(&app), 1)

	// And the status line says what happened, since a zoom has no other announcement.
	press(root, .EQUAL, true)
	status, _ := sa.text(find(&app, "#status"), context.temp_allocator)
	testing.expectf(t, strings.contains(status, "zoom"), "the status should report the zoom: %q", status)
	press(root, .NUM_0, true)
}

// ---- the preview's section window ----------------------------------------------------------------
//
// The preview hands the engine ONE section of the notes, because the assembled document costs 328MB laid
// out in full (`just mem-check`) and this engine cannot un-spend layout: hiding the rest with
// `display: none` from a script measured WORSE than leaving it alone. So the cut is in the text, and these
// tests are about the seam - the wrapper really does cut, the `full` button really does not, and the status
// line says which of the two you are looking at.

@(test)
test_the_preview_carries_one_section_and_full_carries_all :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = "" // no corpus needed: the buffer is written directly

	source := "#+TITLE: T\n\n* One\n\n1C = strong\n\n* Two\n\n2C = weak\n\n* Three\n\n3C = preempt\n"
	set_bml_source(&app, source)
	pump(&app)

	doc := bml.parse(source)
	defer bml.destroy(doc)
	html := bml.render_html(doc, context.temp_allocator)
	testing.expect_value(t, preview.section_count(html), 3)

	// Section 1 (the middle one) and nothing else: the neighbours' own text has to be absent, which is what
	// "the engine never lays it out" means at this level.
	// The DESCRIPTIONS are what a test looks for, not the calls: a bid's suit is rendered as a glyph, so
	// `1C` in the source is `1<span class="ccolor">&#9827;</span>` in the page.
	//
	// The chosen section is there; what is NOT asserted here is that its neighbours are absent, because the
	// window grows forward until it holds something worth reading and these sections are a line each. The
	// exact windows are `preview`'s own tests (`just test-preview`).
	one := preview_document(&app, html, 1, context.temp_allocator)
	testing.expect(t, strings.contains(one, "weak"), "the chosen section must be in the document")
	// Still a document, and still styled: the head and the inlined stylesheet are what make it one.
	testing.expect(t, strings.contains(one, "<style>"), "the preview must keep its stylesheet")
	testing.expect(t, strings.contains(one, "</body>"), "the preview must still close its body")

	// `full` is the same wrapper with -1, and it has everything.
	all := preview_document(&app, html, -1, context.temp_allocator)
	for expected in ([]string{"strong", "weak", "preempt"}) {
		testing.expectf(t, strings.contains(all, expected), "the whole document should hold %s", expected)
	}
	testing.expect(t, len(all) >= len(one), "the whole document cannot be smaller than a slice of it")
}

@(test)
test_the_preview_follows_the_caret_and_says_which_section :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	source := "* One\n\n1C = strong\n\n* Two\n\n2C = weak\n\n* Three\n\n3C = preempt\n"
	set_bml_source(&app, source)
	app.bml_open = strings.clone("scratch.bml", app.allocator)
	pump(&app)

	// A click test needs the handler attached, or "nothing happened" passes without an event being delivered.
	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	// This document is TINY, so the size-based default is the whole thing - which is the fix for a chapter
	// that used to open showing nothing but its first heading.
	rendered, why := preview_bml(&app)
	testing.expectf(t, rendered, "the preview did not render: %s", why)
	testing.expect_value(t, app.bml_scope, Preview_Scope.Unfolded)
	testing.expectf(t, strings.contains(why, "unfolded"), "a small document should open unfolded: %q", why)

	// Folding says which sections are OPEN, because the window grows forward until there is something to read
	// and naming only the first would be a lie.
	click(&app, "#bml-fold")
	pump(&app)
	testing.expect_value(t, app.bml_scope, Preview_Scope.Folded)
	_, section_why := preview_bml(&app)
	testing.expectf(
		t,
		strings.contains(section_why, "folded"),
		"the status should say the document is folded: %q",
		section_why,
	)

	// And back, through the other button of the pair.
	click(&app, "#bml-fold")
	pump(&app)
	testing.expect_value(t, app.bml_scope, Preview_Scope.Unfolded)
}

// A big document defaults the other way, and that is the whole point of the rule: the threshold is the
// document's SIZE, not a fixed preference, because 17KB whole is a few MB and 1.18MB whole is 328MB.
@(test)
test_a_big_document_opens_on_one_section :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	// Enough sections of enough prose to pass `preview.WHOLE_DOCUMENT_MAX` once rendered.
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 140 {
		fmt.sbprintf(&b, "* Section %d\n\n", i)
		for _ in 0 ..< 12 {
			strings.write_string(&b, "some prose about bidding, long enough to add up over sixty sections\n")
		}
		strings.write_string(&b, "\n")
	}
	set_bml_source(&app, strings.to_string(b))
	pump(&app)

	rendered, why := preview_bml(&app)
	testing.expectf(t, rendered, "the preview did not render: %s", why)
	testing.expect_value(t, app.bml_scope, Preview_Scope.Folded)
	testing.expect(t, strings.contains(why, "folded"), "a big document should open folded")
}

// The preview is a TOGGLE, and closing it is what hands the rendered document back to the engine.
@(test)
test_the_preview_button_closes_the_preview :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	app.docs = ""

	app.handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS, .KEY},
		on_event     = on_event,
		user_data    = &app,
	}
	sa.attach_window_handler(app.window, &app.handler)
	defer sa.detach_window_handler(app.window, &app.handler)

	set_bml_source(&app, "* One\n\n1C = strong\n")
	pump(&app)

	click(&app, "#bml-preview")
	pump(&app)
	testing.expect(t, app.bml_showing, "the first press should show the preview")
	testing.expect(t, !effective_display_is_hidden(&app, "#bml-page"), "the pane should be on screen")
	label, _ := sa.text(find(&app, "#bml-preview"), context.temp_allocator)
	testing.expect_value(t, strings.trim_space(label), "close")

	click(&app, "#bml-preview")
	pump(&app)
	testing.expect(t, !app.bml_showing, "the second press should close it")
	testing.expect(t, effective_display_is_hidden(&app, "#bml-page"), "the pane should be off screen")
	closed_label, _ := sa.text(find(&app, "#bml-preview"), context.temp_allocator)
	testing.expect_value(t, strings.trim_space(closed_label), "preview")
}


// The window froze once because a `mouseidle` handler called a method that does not exist
// (`plaintext.popup(...)`, from the SDK's marks sample) and threw on every hover. A handler that throws
// stops the window accepting clicks, and the only trace was an unhandled promise rejection naming the
// engine's own `debug-peer.js`. So: no popups in this document, and the hover path says so out loud.
@(test)
test_the_document_opens_no_popups :: proc(t: ^testing.T) {
	document := compose_document(context.temp_allocator)
	// Not "<popup" in general: the engine renders a `title=` tooltip as one and the stylesheet rightly
	// styles it. What must not come back is a popup THIS document owns, and the call that opens it.
	testing.expect(t, !strings.contains(document, `id="bml-tip"`), "the tip popup is what froze the window")
	testing.expect(t, !strings.contains(document, ".popup("), "nothing here may call an element's popup method")
	// The hover is a status-line message now, and it is guarded: a throw inside it must not escape.
	testing.expect(t, strings.contains(document, "function bmlMessageAt"), "the hover lookup must be there")
	testing.expect(t, strings.contains(document, "catch (x) {"), "the hover handler must catch its own errors")
}

// Every function the editor's script calls on an ELEMENT has to exist, because a typo is not a syntax error
// here - it is a TypeError at the moment a person hovers, and the window stops taking clicks. These are the
// ones this document depends on, checked against the engine rather than against the documentation.
@(test)
test_the_element_methods_the_editor_calls_exist :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)
	set_bml_source(&app, "1C = strong\n")
	pump(&app)

	probe := `(function(){
		var editor = document.$("#bml-text");
		var missing = [];
		var wanted = ["rangeFromPoint", "timer"];
		for (var i = 0; i < wanted.length; i++) {
			if (typeof editor[wanted[i]] !== "function") missing.push(wanted[i]);
		}
		var r = new Range();
		var line = editor.children[0];
		if (line && line.firstChild) {
			r.setStart(line.firstChild, 0);
			r.setEnd(line.firstChild, 1);
			var range_wanted = ["applyMark", "clearMark", "marks"];
			for (var j = 0; j < range_wanted.length; j++) {
				if (typeof r[range_wanted[j]] !== "function") missing.push("Range." + range_wanted[j]);
			}
		} else {
			missing.push("no line to test a Range against");
		}
		return missing.join(",");
	})()`
	result, err := sa.eval(app.window, probe)
	defer sa.value_clear(&result)
	testing.expect_value(t, err, nil)
	missing, _ := sa.value_to_string(&result, context.temp_allocator)
	testing.expectf(t, missing == "", "the editor calls methods this engine does not have: %s", missing)
}

/*
A small text output, echoed into the report pane as well as written to its file.

The deals ARE the output of this window, and up to a point the pane is a better place to read them than a
file somebody has to go and open: `pretty` of a couple of dozen deals is exactly the thing you want to
glance at after pressing generate. Past that it stops being a glance, hence `ECHO_MAX_DEALS` and the
`text_format` test - a 48-board card page is not text, and forty scenarios of it in a transcript would be
neither readable nor cheap (the report pane is a `<plaintext>`, which is NOT virtualised: ~22KB a line,
measured).

Read from the FILE rather than kept from the run: `cli.run` writes the output and hands nothing back, and
re-reading it is both simpler and honest about what was actually written.
*/
ECHO_MAX_DEALS :: 48

echo_output :: proc(app: ^App, path: string) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		transcribe(app, fmt.tprintf("  (could not read %s back: %v)", filepath.base(path), err))
		return
	}
	text := strings.trim_right_space(string(data))
	if text == "" {
		transcribe(app, "  (it is empty)")
		return
	}
	// Line by line, so the pane's own line structure matches the file's: `transcribe` appends one line at a
	// time and the widget's content is its lines (see `draw_transcript`).
	for line in strings.split_lines(text, context.temp_allocator) {
		transcribe(app, line)
	}
}

// ---- the generated file's name, and the echo ------------------------------------------------------
//
// Every text format used to write `<scenario>.txt`, so `pretty` then `line` of one scenario overwrote the
// first and "view page" could not tell them apart. One extension per format fixes both.
@(test)
test_each_format_writes_its_own_extension :: proc(t: ^testing.T) {
	seen := make(map[string]string, 8, context.temp_allocator)
	for format in ([]string{"pretty", "line", "handviewer", "pbn", "lin", "numeric"}) {
		extension := extension_for(format)
		testing.expectf(t, extension != "", "%s has no extension", format)
		if owner, clash := seen[extension]; clash {
			testing.expectf(t, false, "%s and %s would both write %s", owner, format, extension)
		}
		seen[extension] = format
	}
	// The two html formats SHARE `.html` on purpose: a page's kind is read from inside it, which is what
	// keeps a page generated months ago openable.
	testing.expect_value(t, extension_for("html-cards"), ".html")
	testing.expect_value(t, extension_for("html-handviewer"), ".html")
	// And an unknown format is text rather than nothing.
	testing.expect_value(t, extension_for("something-new"), ".txt")
}

// Every option the format dropdown offers has to be a format the parser accepts AND one this side can name a
// file for. A dropdown that offers a format norn rejects is a button that fails.
@(test)
test_every_format_option_is_real :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	element := find(&app, "#format")
	options, err := sa.select_all(element, "option", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, len(options) >= 5, "the dropdown should offer every format")
	for option in options {
		value, _ := sa.attribute(option, "value", context.temp_allocator)
		argv := []string{"-n", "1", "-f", value, "-o", "-"}
		_, ok, message := cli.parse_args(argv)
		testing.expectf(t, ok, "norn rejects the format %q the dropdown offers: %s", value, message)
		testing.expectf(t, extension_for(value) != "", "%q has no extension", value)
	}
}

// A small text run is shown in the pane as well as written to the file — the deals are the output of this
// window, and up to a point the pane is where you want to read them.
@(test)
test_a_small_text_run_is_echoed_into_the_report_pane :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#count", "4")
	type_into(&app, "#seed", "42")
	type_into(&app, "#outdir", PARITY_DIR)
	type_into(&app, "#format", "pretty")

	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	app.job = job
	testing.expect(t, job.echo, "four deals of pretty text is worth echoing")
	testing.expect_value(t, job.ext, ".txt")

	// Write one scenario's output the way the worker does, then echo it.
	path := PARITY_DIR + "/wb-echo.txt"
	argv := make([dynamic]string, 0, len(job.argv) + 4, context.temp_allocator)
	append(&argv, ..job.argv)
	append(&argv, "-S", job.scenarios[0], "-o", path)
	opts, ok, message := cli.parse_args(argv[:])
	testing.expectf(t, ok, "norn rejected the composed argv: %s", message)
	run_ok, run_message := cli.run(bidding.registry, opts)
	testing.expectf(t, run_ok, "the in-process run failed: %s", run_message)
	defer os.remove(path)

	echo_output(&app, path)
	pump(&app)
	transcript := strings.to_string(app.transcript)
	testing.expect(t, len(transcript) > 100, "the deals should be in the pane")
	// `pretty` draws the four hands round a compass, so the pane holds the seat letters.
	testing.expect(t, strings.contains(transcript, "North") || strings.contains(transcript, "N "), "")
	// And what is in the pane is what is in the file.
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	first := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)[0]
	testing.expectf(t, strings.contains(transcript, first), "the pane should hold the file's first line %q", first)
}

// A card page is not text, and forty scenarios of it in a `<plaintext>` would be neither readable nor cheap.
@(test)
test_a_card_page_run_is_not_echoed :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#count", "4")
	type_into(&app, "#outdir", PARITY_DIR)
	type_into(&app, "#format", "html-cards")
	job, cards_err := generate_job(&app)
	testing.expect_value(t, cards_err, "")
	testing.expect(t, !job.echo, "an html page must not be poured into the transcript")

	// Nor is a big text run: past `ECHO_MAX_DEALS` it stops being a glance.
	type_into(&app, "#format", "pretty")
	type_into(&app, "#count", "500")
	big, big_err := generate_job(&app)
	testing.expect_value(t, big_err, "")
	testing.expect(t, !big.echo, "500 deals is not a glance")
	app.job = big
}

// The LIN format exists so a generated deal can be OPENED somewhere - a bridgebase or IntoBridge hand link -
// and read back by the advisor. Both halves are worth pinning here, because they are what make the format
// worth having: the record's shape, and that norn's own reader accepts what norn's writer produced.
@(test)
test_a_generated_lin_record_round_trips :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	type_into(&app, "#count", "3")
	type_into(&app, "#seed", "7")
	type_into(&app, "#outdir", PARITY_DIR)
	type_into(&app, "#format", "lin")
	job, err := generate_job(&app)
	testing.expect_value(t, err, "")
	testing.expect_value(t, job.ext, ".lin")
	testing.expect(t, job.echo, "three deals of text is worth echoing")

	path := PARITY_DIR + "/wb-lin.lin"
	argv := make([dynamic]string, 0, len(job.argv) + 4, context.temp_allocator)
	append(&argv, ..job.argv)
	append(&argv, "-S", job.scenarios[0], "-o", path)
	opts, ok, message := cli.parse_args(argv[:])
	testing.expectf(t, ok, "norn rejected the composed argv: %s", message)
	run_ok, run_message := cli.run(bidding.registry, opts)
	testing.expectf(t, run_ok, "the in-process run failed: %s", run_message)
	defer os.remove(path)

	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	lines := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
	testing.expect_value(t, len(lines), 3)
	for line in lines {
		testing.expectf(t, strings.has_prefix(line, "st||md|"), "not a LIN record: %q", line)
		// The advisor's own reader, on the generator's own output: this is the loop the format is for.
		board, lin_err := norn.parse_lin_deal(line)
		testing.expectf(t, lin_err == .None, "our LIN did not read back: %v (%q)", lin_err, line)
		testing.expect_value(t, card_count(board.deal), DECK_CARDS)
	}
}

// Every card, once. A deal that reads back with 51 cards would still "parse".
@(private = "file")
DECK_CARDS :: 52

@(private = "file")
card_count :: proc(deal: norn.Deal) -> (total: int) {
	for seat in norn.Seat {
		for card in deal[seat] {
			_ = card
			total += 1
		}
	}
	return
}
