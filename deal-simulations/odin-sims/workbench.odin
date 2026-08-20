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
import "core:log"
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
PAGE :: uintptr(5) // a card page is ready in `App.page`; show it in the frame
DEAL :: uintptr(6) // OCR read a deal out of a dropped image; it is in `App.deal`, put it in the box

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
	want_page: bool, // analyse and ocr: the card page into the frame, instead of the text report
	image:     string, // ocr only: the dropped image, an absolute path
}

App :: struct {
	using host: sa.Host_Handler,
	window:     sa.Window,
	handler:    sa.Event_Handler,
	// The drop handler is a SECOND handler, on the document root rather than on the window: measured, the
	// EXCHANGE group does not reach a window handler at all (the drop was refused in silence, which looks
	// exactly like the window not accepting drops). On the root it covers every element in the document,
	// so the whole window is the drop target.
	drops:      sa.Event_Handler,

	// The catalogue, straight from the bidding system. `selected` indexes it.
	scenarios:  []cli.Scenario,
	selected:   int,

	// Shared with the worker. `post_callback` says THAT something changed; the lock is what makes it safe
	// to read WHAT.
	mutex:      sync.Mutex,
	transcript: strings.Builder,
	failure:    string,

	// The card page, rendered by the worker and shown by the engine thread (PAGE). A whole document
	// rather than a line, so it travels here like `failure` does.
	page:       string,

	// The deal OCR read out of a dropped image, travelling to the engine thread (DEAL) so the analyse
	// box shows what was actually read — the OCR is a guess at a picture, and an unreadable digit is a
	// thing to see and correct rather than to have silently analysed.
	deal:       string,

	// The one flag that travels the other way (engine thread -> worker). Atomic because the worker reads
	// it between scenarios and the UI writes it at most once per job.
	cancel:     bool,

	// Engine-thread only, so no lock.
	job:        Job,
	worker:     ^thread.Thread,
	running:    bool,
	allocator:  runtime.Allocator,
}

// Which of the three mutually exclusive top-level views is on screen. They REPLACE each other rather than
// stack, because an overlay wants an out-of-flow percentage height and this engine lays that out 1px tall
// (see the CSS header). One enum rather than three independent toggles: with independent ones, opening
// About over the card page showed both.
View :: enum {
	Panes, // the scenario list + the two command panels: the default
	About,
	Page, // the card page, in the <frame>
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

	state, stdout, stderr, exec_err := os.process_exec(
		{command = command},
		context.temp_allocator,
	)
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
			set_status(app, "the card page could not be loaded into the frame")
		}

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

	argv, flag_err := analyse_flags(app)
	if flag_err != "" {
		return {}, flag_err
	}
	// The deal goes last, as one argument: the parser's positional overflow. Quoting is not a concern
	// here (there is no shell), so the `-` hands of a two-hand deal arrive intact inside this one string.
	append(&argv, deal)

	// No `--html`: the page is asked for in memory (see `analyse.builder_page_sink`) and goes to the
	// frame. Nothing here writes a file, so there is no path to compose and nothing to clean up.
	return Job {
			kind = .Analyse,
			argv = clone_strings(argv[:], app.allocator),
			want_page = read_bool(app, "#as-page"),
		},
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
	for extension in ([]string{".html", ".txt", ".pbn"}) {
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
		return "", .Text, false, fmt.tprintf("nothing generated for %s yet — press generate (looked in %s)", name, dir)
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
	show_view(app, .About if shown else .Panes)
}

// The one place a view is chosen. Every other caller names a `View`, so no combination of buttons can
// leave two of them on screen at once.
show_view :: proc(app: ^App, view: View) {
	set_shown(app, ".panes", view == .Panes)
	set_shown(app, "#about-panel", view == .About)
	set_shown(app, "#pageview", view == .Page)
}

// Which view is on screen. Read from the document rather than remembered — same reason as
// `effective_display_is_hidden`.
current_view :: proc(app: ^App) -> View {
	if !effective_display_is_hidden(app, "#pageview") {
		return .Page
	}
	if !effective_display_is_hidden(app, "#about-panel") {
		return .About
	}
	return .Panes
}

// ---------------------------------------------------------------------------------------------------
// The card page, in the window
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
	show_view(app, .Page)
	focus_page(app)
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
	show_view(app, .Page)
	focus_page(app)
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
		note = fmt.tprintf("<div class=\"note\">showing the first %d KB of %d KB</div>", TEXT_CAP / 1024, len(data) / 1024)
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
		win.ShellExecuteW(
			nil,
			win.utf8_to_wstring("open"),
			win.utf8_to_wstring(path),
			nil,
			nil,
			win.SW_SHOWNORMAL,
		)
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
			Job {
				kind = .Analyse,
				argv = clone_strings(argv[:], app.allocator),
				want_page = read_bool(app, "#as-page"),
			},
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
			fmt.tprintf("%s is not something this window reads — drop a hand-diagram image, a .pbn/.lin, or a page", filepath.base(path)),
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
				set_status(app, "the card page could not be loaded into the frame")
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

	case "page-close":
		show_view(app, .Panes)
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
		note_selected_page(app)
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
		subscription = {.BEHAVIOR_EVENT, .MOUSE, .FOCUS},
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

	// Pre-fill the output directory so the field is never a blank the user has to guess at, and so the
	// destination is VISIBLE before a batch rather than inferred afterwards: DEALS_OUTPUT_DIR when set (the
	// justfile exports the same `w:/deals/` default the `gen-all` recipes use), else this process's working
	// directory, spelled absolutely — the exact thing a relative path would have resolved against.
	out_dir, out_note := default_out_dir(context.temp_allocator)
	set_input(app, "#outdir", out_dir)

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
	set_text_at(
		app,
		"#about-book",
		"Suit-combination tables in the card-page analysis are baked from the BridgeHands suit-combination pages; the lines and percentages are facts of the game, the wording and arrangement are theirs.",
	)
	// The page-geometry dump is a development affordance: the stylesheet hides it, and only a `-debug` build
	// puts it on screen.
	when ODIN_DEBUG {
		set_shown(app, "#page-dump", true)
	}

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
	delete(app.page)
	free(app)
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
		fmt.eprintfln("graphics: the engine's own default layer, a GPU one (legacy caps rating: %v, ok=%v)", caps, caps_ok)
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

	for selector in ([]string{"#engine", "#scenarios", "#count", "#format", "#seed", "#outdir", "#dd", "#fixed", "#all", "#generate", "#cancel", "#view-page", "#fill", "#status", "#deal", "#sample", "#contract", "#target", "#as-page", "#analyse", "#clear", "#report", ".panes", "#about", "#about-panel", "#about-close", "#about-sciter-link", "#about-versions", "#about-book", "#pageview", "#page", "#page-title", "#page-dump", "#page-close"}) {
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
FRAME_DOC :: `<html><head><meta charset="utf-8"></head><body><div id="probe" class="compass">before</div>` +
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
	testing.expect_value(t, current_view(&app), View.Page)
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
// About is asked for while the page is up. (That combination showed both before `show_view` existed.)
@(test)
test_the_page_view_replaces_the_other_views :: proc(t: ^testing.T) {
	app: App
	if !test_app(t, &app) {return}
	defer test_app_destroy(&app)

	testing.expect_value(t, current_view(&app), View.Panes)

	testing.expect(t, show_page_html(&app, FRAME_DOC, "a test document"), "the frame must accept the document")
	pump(&app)
	testing.expect_value(t, current_view(&app), View.Page)
	title, _ := sa.text(find(&app, "#page-title"), context.temp_allocator)
	testing.expect_value(t, title, "a test document")

	// About while the page is up shows About ONLY.
	show_about(&app, true)
	testing.expect_value(t, current_view(&app), View.About)
	testing.expect(t, effective_display_is_hidden(&app, "#pageview"), "the page view must be hidden by About")

	// And going back to the panes takes the frame off screen, which is what `page-close` does.
	show_view(&app, .Page)
	testing.expect_value(t, current_view(&app), View.Page)
	show_view(&app, .Panes)
	testing.expect_value(t, current_view(&app), View.Panes)
	testing.expect(t, effective_display_is_hidden(&app, "#pageview"), "and the frame goes away with it")
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
