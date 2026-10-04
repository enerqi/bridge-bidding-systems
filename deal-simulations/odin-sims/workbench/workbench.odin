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
import "core:thread"
import "core:time"

import "../analyse"
import "../bidding"
import "../deal_solve"
import "../outline"
import "../perf"
import "../prefs"
import "../preview"
import "../scenario_dsl"
import "../sim_hooks"
import "../suit_book"
import bml "markup:."
import "norn:cli"
import "norn:combo"
import sciter "sciter:."
import sa "sciter:sciter_app"

// The UI, compiled in. Two files rather than one so the CSS keeps its own syntax highlighting and its own
// header comment; they are stitched at startup by replacing the `/*CSS*/` marker, which is a token rather
// than a `%s` because CSS is full of `%`.
UI_HTML :: #load("../ui/workbench.html", string)
UI_CSS :: #load("../ui/workbench.css", string)
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
FOLLOW :: uintptr(8) // the hand page follow`s debounce ran out; load the selection`s page (same reason)

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
	using host:         sa.Host_Handler,
	window:             sa.Window,
	handler:            sa.Event_Handler,
	// The drop handler is a SECOND handler, on the document root rather than on the window: measured, the
	// EXCHANGE group does not reach a window handler at all (the drop was refused in silence, which looks
	// exactly like the window not accepting drops). On the root it covers every element in the document,
	// so the whole window is the drop target.
	drops:              sa.Event_Handler,

	// The catalogue, straight from the bidding system. `selected` indexes it.
	scenarios:          []cli.Scenario,
	selected:           int,

	// USER-AUTHORED SCENARIOS, parsed from `.scenario` files at startup, and the registry they extend.
	// `scenarios` is the CONCATENATION — compiled first, loaded second — so everything downstream (the
	// list, the filter, the chips, generate) treats the two alike. `loaded` is kept because it owns the
	// programs the interpreted conditions point into, and because it carries their declared tags.
	loaded:             scenario_dsl.Loaded,
	scenario_dirs:      []string,

	// THE GROUPS, merged. `bidding.tags` is the compiled system's own vocabulary; a `.scenario` file may
	// declare tags of its own (`tags: mine, competitive`), and one that named a group with no picker row
	// would be a scenario nobody could select. So the picker lists the union, and `from_files` is what
	// lets a row say where a group came from.
	groups:             []Group,

	// WHICH GROUPS ARE SELECTED, one flag per entry of `groups` and in that order. Parallel flags
	// rather than a list of names: the set is small, fixed and known at startup, so there is no allocation
	// to own and no name to misspell — and "is this tag on" is the question every drawing path asks.
	//
	// NOT REMEMBERED ACROSS SESSIONS, deliberately, and for the same reason the text filter is not: a
	// window that opened showing 31 of 110 scenarios because of something chosen last week is a window
	// that looks broken. Both narrowing controls start empty and say so.
	tag_on:             []bool,

	// Shared with the worker. `post_callback` says THAT something changed; the lock is what makes it safe
	// to read WHAT.
	mutex:              sync.Mutex,
	transcript:         strings.Builder,
	failure:            string,

	// The card page, rendered by the worker and shown by the engine thread (PAGE). A whole document
	// rather than a line, so it travels here like `failure` does.
	page:               string,

	// The deal OCR read out of a dropped image, travelling to the engine thread (DEAL) so the analyse
	// box shows what was actually read — the OCR is a guess at a picture, and an unreadable digit is a
	// thing to see and correct rather than to have silently analysed.
	deal:               string,

	// The one flag that travels the other way (engine thread -> worker). Atomic because the worker reads
	// it between scenarios and the UI writes it at most once per job.
	cancel:             bool,

	// The BML editor, all engine-thread state. `docs` is where the `.bml` corpus was found (empty if it
	// was not), `bml_names` the files in it, and `bml_open` the one in the editor — a name rather than an
	// index, so a re-listed directory cannot silently change which file `save` writes to.
	// The view About was entered from, so closing it goes back there rather than to the panes.
	before_about:       View,
	before_keys:        View, // the same, for the keys list — see the `Keys` member of `View`
	before_prefs:       View, // and for the preferences view
	// Views that were HIDDEN when the theme last changed. A hidden subtree is not restyled with the rest
	// (measured: it kept the old theme's colours when shown again), so `show_view` restyles each of these
	// the first time it is shown afterwards — see `theme.odin`.
	theme_stale:        bit_set[View],

	// What the LAST hand-page load cost, which is what the follow's debounce is scaled by. These pages run
	// from a few KB to ~86MB, so no fixed delay suits both ends (see `page_follow_delay`).
	page_load_cost:     time.Duration,

	// Is there a hand page to show? The deals bar`s `hand page` and `wide` are disabled until there is, and `do_click`
	// does NOT honour a disabled button (measured — the behavior runs and the click is delivered), so the
	// tab handler asks this rather than trusting the attribute. Rule 1: the model is the truth and the
	// `disabled` attribute is the projection of it.
	page_ready:         bool,

	// Is a transcript redraw already on its way? Claimed by `transcribe` (any thread) and cleared by the
	// handler that draws it, so a burst of lines costs ONE post instead of one each.
	transcript_pending: b32,

	// The file currently in the pane, so the chip for it can say so. Empty for a page that came from
	// `analyse` rather than off disk - that page is not a format of a scenario, and no chip should claim it.
	shown_path:         string,

	// What is in the deals folder, scenario name -> the formats generated for it. One `read_dir` fills it
	// (see `scan_outputs`); the list rows and the format chips are both projections of it.
	outputs:            map[string]Format_Set,

	// Where the splitter between the controls and the hand page was last left, as the engine's own length
	// strings joined by commas (`250px,1*,2*`). Held here rather than read on demand for one reason: `wide`
	// HIDES the controls, and a hidden pane drops out of the frameset's state, so the three-pane reading has
	// to be taken while all three are still there. Written to the prefs file, so a dragged split survives a
	// restart the way the zoom does.
	// THE DEALS VIEW'S PANE WIDTHS, as a model: the one place they live. `apply_deal_layout` renders the
	// frameset from it and from which panes are shown; nothing else writes the frameset (see the note there).
	deal_layout:        Deal_Layout,

	// Is there a rendered preview in the frame? Once there is, it FOLLOWS the buffer — opening another file
	// re-renders it, because a preview of the file you were looking at a moment ago is worse than no
	// preview: it looks like the file you just clicked.
	previewed:          bool,
	docs:               string,
	bml_names:          []string,
	bml_open:           string,
	bml_crlf:           bool, // the line endings the file arrived with, so saving does not rewrite all of them
	bml_armed:          bool, // a switch away from unsaved text was refused once; the next one goes through
	// Check `[label](#Anchor)` as well? Off by default, and the button says so: a CHAPTER of this corpus
	// links to headings in its sibling files on purpose, so on one chapter the check is mostly noise. On
	// `bidding-system.bml`, which includes them all, every warning it raises is a real broken link.
	bml_links:          bool,
	// How much of the notes the preview shows, and whether the pane is up at all. `bml_scope` is per FILE
	// (see `scope_for_file`): remembered if it was chosen, otherwise decided by the document's size.
	bml_scope:          Preview_Scope,
	// Has the scope been settled for the file that is open? The size-based default is applied ONCE per file;
	// after that the state is whatever it is, or a press of `section`/`whole` would be undone by the very
	// re-render it asks for.
	bml_scope_set:      bool,
	bml_showing:        bool, // is the preview pane up? `preview` closes it, and closing it frees the document
	// THE PREVIEW IS LIVE: once the pane is up it follows the buffer, on a debounce, without being asked.
	// `bml_live_base` is the idle a keystroke has to survive before a render (0 turns the whole thing off),
	// `bml_preview_cost` is how long the LAST render took - which is what the debounce is scaled by, so a
	// document that is expensive to render is also one that is left alone for longer. `bml_rendering` is the
	// re-entrancy guard: a render pumps the engine, so a second one must not start inside the first.
	// `bml_rendered` fingerprints the text the pane is showing, so a timer that fires over an unchanged
	// buffer (an arrow key, a modifier, an edit that was undone) costs nothing.
	// THE SCENARIO EDITOR, all engine-thread state and the same shape as the BML editor's above: `scn_dir`
	// is the folder being edited, `scn_names` the `.scenario` files in it, and `scn_open` the one in the
	// buffer — a NAME rather than an index, so a re-listed directory cannot change which file `save`
	// writes to. It is a separate folder from `docs` because they hold different things; adopting the
	// notes folder for scenarios would only be a coincidence that worked once.
	scn_dir:            string,
	scn_names:          []string,
	scn_open:           string,
	scn_crlf:           bool, // the line endings the file arrived with, so saving does not rewrite them all
	scn_armed:          bool, // a switch away from unsaved text was refused once; the next one goes through
	bml_live_base:      time.Duration,
	bml_preview_cost:   time.Duration,
	bml_rendering:      bool,
	bml_rendered:       u64,

	// The heading palette (CTRL+R). `goto_all` is the whole corpus's headings, OWNED (see `build_goto_index`
	// - the files' text is read, the headings cloned out of it and the text dropped); `goto_rows` is what the
	// list on screen is showing, in list order, so a click or ENTER can name a destination by row rather
	// than by re-running the ranking and hoping it comes out the same. `goto_sel` is the highlighted row.
	goto_open:          bool,
	goto_sel:           int,
	goto_all:           []outline.Heading,
	goto_rows:          []outline.Heading,
	// The preview scroll that has not landed yet, and how many times it has been tried. A frame's
	// sub-document is laid out on the engine's schedule, so the scroll is RETRIED on a timer until the
	// numbers say it moved - see `scroll_preview_to_heading`.
	scroll_want:        string,
	scroll_tries:       int,
	frame_handler:      sa.Event_Handler,
	page_handler:       sa.Event_Handler, // the hand page frame`s, for the follow timer
	prefs:              prefs.Prefs,
	prefs_path:         string,

	// Engine-thread only, so no lock.
	job:                Job,
	worker:             ^thread.Thread,
	running:            bool,
	allocator:          runtime.Allocator,
}

// Which of the three mutually exclusive top-level views is on screen. They REPLACE each other rather than
// stack, because an overlay wants an out-of-flow percentage height and this engine lays that out 1px tall
// (see the CSS header). One enum rather than three independent toggles: with independent ones, opening
// About over the hand pane showed both.
View :: enum {
	Panes, // the scenario list, the command panels, and the hand page beside them: the default
	About,
	Editor, // the BML editor, source and preview side by side
	Scenarios, // the `.scenario` editor: the files, the source, and what a check made of it
	// THE KEYS LIST IS A VIEW, not a pane of the deals view, and that was a correction. It first borrowed
	// `#report`, which lives in `.work` — so CTRL+/ in the NOTES view opened it somewhere the notes view
	// does not show, invisibly, leaving the deals view's report pane hidden for when you came back. It is
	// what `About` is: a reference errand entered from anywhere and left by going back to where you were.
	Keys,
	// PREFERENCES, the same errand shape again: entered from the header's gear, left by going back.
	Prefs,
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

		// `app.scenarios`, NOT `bidding.registry`: the list this window generates from is the concatenation
		// of the compiled scenarios and the ones loaded from `.scenario` files, so running the compiled
		// registry alone meant a text scenario could be selected, named in the status line, and then fail
		// with "unknown scenario" the moment generate was pressed. Safe to read here because the registry
		// is only ever rebuilt by `reload_scenarios`, which refuses while a job is running.
		run_ok, run_message := cli.run(app.scenarios, opts)
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
	trim_transcript(app)
	sync.unlock(&app.mutex)

	// ONE POST PER BURST. The engine thread redraws the WHOLE transcript for each of these, so a post per
	// line is quadratic in the length of the run and it is the worker, not the user, setting the pace: a
	// fast loop can queue thousands before the first is dispatched. The flag is claimed here and cleared by
	// the handler, so a line written while a redraw is in flight schedules exactly one more.
	if !sync.atomic_exchange(&app.transcript_pending, true) {
		sa.post_callback(app.window, TRANSCRIPT)
	}
}

/*
THE TRANSCRIPT IS BOUNDED, because the pane it goes into is not virtualised.

The report pane is a `<plaintext>` and costs ~22KB per LINE, measured — so an unbounded transcript is a
memory bug waiting for a long enough run, and the redraw that rewrites its whole content gets slower with
every line. Keeping the tail is the right half to keep: the end of a run is what says how it went.

Called with the mutex HELD (both callers are inside it). Cutting on a line boundary means the pane never
shows half a line, and the marker says the middle is gone rather than leaving someone to wonder.
*/
TRANSCRIPT_CAP :: 512 * 1024
TRANSCRIPT_KEEP :: 384 * 1024 // what is left after a trim, so trimming is rare rather than per line

trim_transcript :: proc(app: ^App) {
	text := strings.to_string(app.transcript)
	if len(text) <= TRANSCRIPT_CAP {
		return
	}
	tail := text[len(text) - TRANSCRIPT_KEEP:]
	if cut := strings.index_byte(tail, '\n'); cut >= 0 {
		tail = tail[cut + 1:]
	}
	kept := strings.clone(tail, context.temp_allocator)
	strings.builder_reset(&app.transcript)
	strings.write_string(&app.transcript, "… earlier lines dropped (the report pane keeps the tail)\n")
	strings.write_string(&app.transcript, kept)
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
		// Cleared BEFORE the draw, not after: a line written while this redraw is running belongs to the
		// next one, and clearing afterwards would drop it.
		sync.atomic_store(&app.transcript_pending, false)
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
		job_ended(app, show_result = posted.lparam != 1)

	case FOLLOW:
		// THE SELECTION SETTLED, so the pane can catch up. Posted for the same reason `LIVE` is, and it is
		// the same hazard: the load REPLACES the framed document, and doing that inside the frame`s own
		// timer dispatch tears out the tree the engine is dispatching into.
		follow_selection_tick(app)

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
job_ended :: proc(app: ^App, show_result := false) {
	generated := app.job.kind == .Generate
	if app.worker != nil {
		thread.join(app.worker)
		thread.destroy(app.worker)
		app.worker = nil
	}
	job_free(&app.job, app.allocator)
	sync.atomic_store(&app.cancel, false)
	app.running = false
	ui_thread_priority(false)
	set_enabled(app, "#generate", true)
	set_enabled(app, "#analyse", true)
	set_enabled(app, "#cancel", false)

	// The pane segment IS re-asked here, and this is the one place it must be: a run writes pages to disk
	// without putting any of them in the frame, so "is there a page to show" has just changed for a control
	// that has no other way to find out. (Which scenario's page it would show still comes from the
	// SELECTION, not from what this run happened to write - a batch of 110 leaves the selected scenario's
	// page exactly where the segment looks for it.)
	scan_outputs(app) // the run just wrote files; the tags and the chips are how that shows
	draw_scenarios(app)
	refresh_pane_segment(app)
	note_selected_page(app)

	// AND THE RESULT IS SHOWN. Reported: generate with the hand page open changed nothing on screen - the
	// run rewrote the file the pane was showing and the pane kept the old load of it, so a new set of deals
	// looked like the old one. A completed generate run now puts the selected scenario's newest output in
	// the pane, the way pressing its chip would (and opening the pane, as a page arriving always does).
	// Not after a cancel or a failure, and never a handviewer page, which would launch a browser.
	if show_result && generated {
		if _, kind, found, _ := selected_output(app); found && kind != .Handviewer {
			show_selected_page(app, follow = false)
		}
	}
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

/*
THE WINDOW OUTRANKS THE WORK, for as long as the work is running.

A generate run saturates this machine on purpose: the worker thread drives `cli.run`, and on the html-cards
path `combo`'s own pool takes up to 16 more (`min(physical cores, POOL_MAX_WORKERS)`). All of them are
normal-priority, and so is the thread pumping the window - so the UI thread waits its turn with everything
else, and a turn it does not get inside about five seconds is what Windows paints "(Not Responding)" for.
The app is working perfectly at that moment, which is the worst version of this: the window says it has
crashed while the terminal behind it prints a scenario a second.

Raising the ENGINE thread rather than lowering the workers is the version that holds: `combo` starts its
pool inside norn where this program has no say, and lowering only what we own would leave the pool at the
same priority as the pump. A pump that runs a few milliseconds more often costs the batch nothing
measurable - it is idle almost all of that time - and it is the difference between a window that repaints
its progress bar and one that looks dead.

Windows-only, because that is where the symptom was reported and where `SetThreadPriority` is one call.
Restored when the job ends, so nothing outside a run is affected.
*/
ui_thread_priority :: proc(boosted: bool) {
	when ODIN_OS == .Windows {
		win.SetThreadPriority(
			win.GetCurrentThread(),
			win.THREAD_PRIORITY_ABOVE_NORMAL if boosted else win.THREAD_PRIORITY_NORMAL,
		)
	}
}

// THE TWO PRIMARY ACTIONS, each behind a proc so the button and the key are the same path rather than two
// copies of the same six lines. Both compose an argv out of the DOM and hand it to `start_job`, which is
// the only thing that starts a worker.
start_generate :: proc(app: ^App) {
	job, err := generate_job(app)
	if err != "" {
		set_status(app, err)
		return
	}
	start_job(
		app,
		job,
		fmt.tprintf("generating %d scenario%s…", len(job.scenarios), "" if len(job.scenarios) == 1 else "s"),
	)
}

start_analyse :: proc(app: ^App) {
	job, err := analyse_job(app)
	if err != "" {
		set_status(app, err)
		return
	}
	start_job(app, job, "analysing…")
}

// Start a job. The argument lists are already cloned into `app.allocator` by the caller (they were read
// out of the DOM, whose strings are temp memory).
start_job :: proc(app: ^App, job: Job, status: string) {
	if app.running {
		return
	}
	// THE GROUP PICKER BORROWED THE REPORT PANE, and a run wants it back: the transcript is the thing worth
	// looking at while one is going, and a picker left sitting over it is the same failure as the pane
	// segment that stayed dead after generate — the window showing the wrong thing because nobody told it
	// the situation had changed.
	set_tag_picker(app, false)
	app.job = job
	app.running = true
	// The pump outranks the work while the work is on - see `ui_thread_priority`.
	ui_thread_priority(true)
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
			// For the echo below. THREE conditions, and the third was the missing one: a text format, a
			// small enough run, AND ONE SCENARIO. `every scenario` in `pretty` echoed all 110 runs - about
			// 74,000 lines into a `<plaintext>` that is not virtualised, one full-content rewrite per line -
			// and the window stopped answering for the length of the batch with the progress bar never
			// getting a frame to paint in. A batch writes files; the glance is for the one you asked for.
			echo      = text_format(format) && n <= ECHO_MAX_DEALS && len(names) == 1,
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
/*
WHAT HAS BEEN GENERATED, FOR EVERY SCENARIO AT ONCE.

The window`s hierarchy is FOLDER -> SCENARIO -> FORMAT: the bar says which folder, the list says which
scenario, and until now nothing said which formats were in it. Browsing the list told you the names of
scenarios that might have nothing behind them, and the only way to find out was to press something.

It is ONE `read_dir` rather than a probe per row. Seven extensions across 101 scenarios is 707 `stat` calls
per redraw, on a directory that by default lives on a network share; a single listing is one round trip and
answers the whole question. Re-read when the folder could have changed - the field is left, a run ends, the
window starts - and never per keystroke.

`.hv.txt` is matched BEFORE `.txt`, or every handviewer file would be read as pretty text: the longest
extension wins, which is the only rule this needs. The two html formats share `.html` on purpose and are
still told apart by looking INSIDE the file (`file_kind`); the tag says `html` for both, because what the
tag is for is "there is something here", and the kind is decided when it is opened.
*/
Deal_Format :: enum {
	Html, // html-cards: the interactive page this window hosts
	Html_Handviewer, // html-handviewer: an <iframe> per deal onto bridgebase.com, for a real browser
	Pbn,
	Lin,
	Handviewer,
	Line,
	Numeric,
	Text,
}

Format_Set :: bit_set[Deal_Format]

// Longest-first, which is what makes `.hv.txt` win over `.txt`.
FORMAT_EXTENSIONS :: [Deal_Format]string {
	.Html            = ".html",
	// `.hv.html`, and the reason is the one already written above for `.hv.txt`: ONE EXTENSION PER FORMAT.
	// Both html formats wrote `<scenario>.html`, so generating a scenario as html-cards and then as
	// html-handviewer OVERWROTE the first with no warning, exactly the collision the text formats were
	// given their own extensions to fix - and the chip row could only ever show one `html` chip for two
	// different things. Reported as "the html-handviewer format takes over the html button, should really
	// have 2 different buttons".
	//
	// Files already on disk from before this predate the split and are all `.html`; `file_kind` still
	// looks INSIDE an `.html` to decide which kind it is, so they keep opening correctly.
	.Html_Handviewer = ".hv.html",
	.Pbn             = ".pbn",
	.Lin             = ".lin",
	.Handviewer      = ".hv.txt",
	.Line            = ".line",
	.Numeric         = ".num",
	.Text            = ".txt",
}

// What the tag says. Short because it sits in a list row 250px wide.
FORMAT_TAGS :: [Deal_Format]string {
	.Html            = "cards",
	.Html_Handviewer = "bbo",
	.Pbn             = "pbn",
	.Lin             = "lin",
	.Handviewer      = "hv",
	.Line            = "line",
	.Numeric         = "num",
	.Text            = "text",
}

format_of_extension :: proc(file: string) -> (base: string, format: Deal_Format, ok: bool) {
	extensions := FORMAT_EXTENSIONS
	longest := 0
	for extension, candidate in extensions {
		if !strings.has_suffix(file, extension) || len(extension) <= longest {
			continue
		}
		base, format, ok, longest = file[:len(file) - len(extension)], candidate, true, len(extension)
	}
	return
}

// Read the deals folder and remember what is in it. Cheap enough to call whenever the folder could have
// changed, and deliberately silent about a folder that is not there: an unset or mistyped path is a state
// the window shows in the status line, not an error to raise here.
scan_outputs :: proc(app: ^App) {
	clear_outputs(app)
	typed := strings.trim_space(read_text(app, "#outdir"))
	if typed == "" {
		return
	}
	dir, abs_err := filepath.abs(typed, context.temp_allocator)
	if abs_err != nil {
		return
	}
	handle, open_err := os.open(dir)
	if open_err != nil {
		return
	}
	defer os.close(handle)
	files, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != nil {
		return
	}
	for file in files {
		if file.type == .Directory {
			continue
		}
		base, format, ok := format_of_extension(file.name)
		if !ok {
			continue
		}
		if have, found := &app.outputs[base]; found {
			have^ += {format}
			continue
		}
		app.outputs[strings.clone(base, app.allocator)] = {format}
	}
}

clear_outputs :: proc(app: ^App) {
	for name in app.outputs {
		delete(name, app.allocator)
	}
	clear(&app.outputs)
}

// What the given scenario has, as tags in the order the enum declares them - so a row always reads the same
// way and two rows can be compared at a glance.
formats_for :: proc(app: ^App, name: string) -> Format_Set {
	return app.outputs[name] or_else {}
}

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
// How much of an `.html` output is read to tell a cards page from a handviewer one. Both markers are in the
// document's head, and this is generous for them.
OUTPUT_HEAD_BYTES :: 16 * 1024

file_kind :: proc(path: string) -> Output_Kind {
	if !strings.has_suffix(path, ".html") {
		return .Text
	}
	// THE HEAD, AND ONLY THE HEAD. This read the WHOLE file and then sliced 16KB off the front of it, which
	// is a full read of a page that can be tens of megabytes — over the network share this folder points at
	// by default — to look at its first sixteen kilobytes. It runs on every selection change, from both
	// `selected_output` and `draw_output_chips`, so holding an arrow key down was pulling a card page
	// across the wire twice per row. The old comment said "a 48-deal page is a quarter of a megabyte" and
	// that has not been true for a long time.
	handle, oerr := os.open(path, os.O_RDONLY)
	if oerr != nil {
		return .Cards // unreadable: let the frame report it rather than guessing a browser hand-off
	}
	defer os.close(handle)
	buffer := make([]u8, OUTPUT_HEAD_BYTES, context.temp_allocator)
	read, rerr := os.read(handle, buffer)
	if rerr != nil || read <= 0 {
		return .Cards
	}
	head := string(buffer[:read])
	if strings.contains(head, "nc-track") {
		return .Cards
	}
	if strings.contains(head, "handviewer") || strings.contains(head, "<iframe") {
		return .Handviewer
	}
	return .Cards
}

/*
WHAT PICKING A SCENARIO DOES.

Two things. It says what the selection HAS in the status line and on the chip row below the bar, and IF THE
PANE IS ALREADY OPEN it shows that scenario's page there.

The follow is conditional on purpose. A hand page is up to ~86MB of laid-out document, so arrowing down a
101-scenario list must not load one per row — an OPEN pane is someone saying they are looking at pages, and
a closed one is not. And the follow never opens the pane by itself: opening it is the segment's job, and a
list click that changed the shape of the window would be doing two things at once.

The handviewer kind is never followed, in either state. Those pages embed bridgebase.com and want a real
browser, and no click in a LIST should launch one. THE CHIP IS WHERE THAT LIVES NOW: the chip for a format
that leaves the window carries an ↗ mark, so pressing it is a deliberate act by someone who can see what it
is about to do. The standalone `browser` button that used to appear for this went with it — it said the same
thing for the newest output only, in a second place, and two controls for one act is one too many.
*/
note_selected_page :: proc(app: ^App) {
	if app.running {
		return // the status line belongs to the run while one is going
	}
	path, _, ok, why := selected_output(app)
	refresh_pane_segment(app)
	draw_output_chips(app)
	if !ok {
		set_status(app, why)
		return
	}
	set_status(app, fmt.tprintf("output: %s", path))
	if page_pane_shown(app) {
		arm_page_follow(app)
	}
}

/*
THE FOLLOW IS DEBOUNCED, because a page is not a cheap thing to show.

Reported: "cpu now high after opening html view and bashing some arrow keys whilst a scenario was selected".
The follow loaded a page PER KEYSTROKE — a multi-megabyte document parsed and laid out, once per row
stepped past — so arrowing down the list queued dozens of them and the engine churned long after the keys
stopped. The conditional follow was already the first defence (a CLOSED pane loads nothing at all); this is
the second, and it is the one that covers an open one.

SCALED BY WHAT A LOAD COSTS, exactly like the BML preview's: these pages run from a few KB to ~86MB and no
fixed delay is right for both. The last load's own duration is the estimate, capped so the pane never feels
abandoned.

The delay is not a nicety here — it is the difference between "arrowing browses the list" and "arrowing
starts a hundred page loads", and the two feel nothing alike.
*/
PAGE_FOLLOW_TIMER :: sa.Timer_Id(9)
PAGE_FOLLOW_BASE :: 180 * time.Millisecond
PAGE_FOLLOW_MAX :: 3 * time.Second

page_follow_delay :: proc(app: ^App) -> time.Duration {
	delay := PAGE_FOLLOW_BASE
	if scaled := app.page_load_cost * 4; scaled > delay {
		delay = scaled
	}
	return min(delay, PAGE_FOLLOW_MAX)
}

// Restart the countdown. `set_timer` with the same id REPLACES the timer, which IS the debounce: a burst of
// arrow presses leaves exactly one load, of the row the arrows stopped on.
arm_page_follow :: proc(app: ^App) {
	frame := find(app, "#page")
	if frame == nil {
		return
	}
	_ = sa.set_timer(frame, page_follow_delay(app), PAGE_FOLLOW_TIMER)
}

// The countdown ran out: the arrows stopped. Loads the selection's page unless the pane is already showing
// it — which is the common case after a burst that ended where it started.
follow_selection_tick :: proc(app: ^App) {
	if !page_pane_shown(app) || current_view(app) != .Panes {
		return // the pane was closed, or the view left, while the timer ran
	}
	if shown_page_is_the_selection(app) {
		return
	}
	started := time.now()
	show_selected_page(app, follow = true)
	app.page_load_cost = time.since(started)
}

/*
The file the pane is showing, so one chip can say "this one". Cleared for a page built in memory.

AND IT REDRAWS THE CHIPS, which is not tidiness - it is the fix for a reported bug. The chips were drawn by
`note_selected_page` BEFORE the follow loaded anything, so on the first click of a scenario the row went up
with the PREVIOUS file's chip lit (or none at all), and only a second selection - or pressing a chip - ever
agreed with what was in the pane. Every path that shows a file passes through here, so this is the one place
that knows the answer has changed.

The redraw is pure projection: it reads `app.outputs` and the DOM and loads nothing, so it cannot re-enter
the show it was called from.
*/
remember_shown_path :: proc(app: ^App, path: string) {
	if app.shown_path != "" {
		delete(app.shown_path, app.allocator)
	}
	app.shown_path = strings.clone(path, app.allocator) if path != "" else ""
	// The pane`s own `browser` button acts on this, so it is alive exactly when there is a FILE behind what
	// is on screen - not for a page `analyse` built in memory - AND WHEN THAT FILE IS A PAGE.
	//
	// The second half was reported: "the browser button uses the OS default, so not really a browser for
	// text, lin files etc". `open_in_browser` is a SHELL OPEN, so a `.txt` goes to Notepad and a `.lin` to
	// whatever claims it - which is not what a button labelled `browser` promises, and for a `.lin` it is
	// a file association this window has no business firing. A page is the only thing a browser is the
	// right answer for, and the pane can already show the rest as text.
	set_enabled(app, "#page-browser", browsable_page(app.shown_path))
	draw_output_chips(app)
}

/*
THE THIRD LEVEL OF THE HIERARCHY: EVERY FORMAT, ALWAYS, IN THREE STATES.

The folder is in the bar, the scenario is in the list, and this row is the format. It shows all seven every
time - not just the ones that exist - because a row that only listed what was there could say "this scenario
has html and text" but never "and no pbn": absence had no shape, and comparing two scenarios meant comparing
two DIFFERENT sets of chips. A fixed row in a fixed order is read by position, and the greyed ones are the
answer to the question the old row could not express.

	dim + dead   nothing generated in this format
	neutral      there is a file; pressing it shows that file
	lit          this is what the pane is showing

The lit state matters because the chips are the only thing that says WHICH of several files you are looking
at. `selected_output` resolves the NEWEST, so with a page and a pbn on disk the window would otherwise show
one of them with nothing on screen saying which.

Nothing here probes the filesystem for existence - that is the one `read_dir` the list rows also use. The
ONE file it does read is the selected scenario`s `.html`, and only its head (`file_kind`), because the two
html formats share the extension and a HANDVIEWER page has to be marked as going to the browser rather than
into the pane.
*/
draw_output_chips :: proc(app: ^App) {
	row := find(app, "#outputs")
	if row == nil {
		return
	}
	if app.selected < 0 || app.selected >= len(app.scenarios) {
		sa.set_html(row, "")
		set_shown(app, "#outputs", false)
		return
	}
	name := app.scenarios[app.selected].name
	have := formats_for(app, name)
	extensions := FORMAT_EXTENSIONS
	tags := FORMAT_TAGS

	// Where each chip`s file would be. Resolved once for the row rather than per chip.
	typed := strings.trim_space(read_text(app, "#outdir"))
	dir := ""
	if typed != "" {
		if absolute, abs_err := filepath.abs(typed, context.temp_allocator); abs_err == nil {
			dir = absolute
		}
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `<span class="head">%s</span>`, escape_html(name, context.temp_allocator))
	for format in Deal_Format {
		exists := format in have
		path := ""
		if exists && dir != "" {
			path, _ = filepath.join({dir, fmt.tprintf("%s%s", name, extensions[format])}, context.temp_allocator)
		}
		// THE BROWSER MARK GOES WHERE A BROWSER ACTUALLY OPENS, which is NOT where it was first put.
		//
		// `hv` is `-f handviewer`: bridgebase QUERY STRINGS, one deal a line, in a `.hv.txt`. It is text -
		// `file_kind` says so, pressing it shows it in the pane as text, and it always did. The mark on it
		// was reading the FORMAT`s name and promising a browser that nothing was ever going to open
		// (reported: "why does hv have the browser link arrow but no way to open in browser").
		//
		// The one output this window cannot host is an `html-handviewer` PAGE: an `<iframe>` per deal onto
		// bridgebase.com, which in the frame makes dozens of https requests and then reports javascript as
		// disabled. Both html formats write `.html`, so which one this is comes from inside the file, and
		// the mark follows that - the same answer the press will act on.
		browser := exists && format == .Html && path != "" && file_kind(path) == .Handviewer
		// The mark for "this one leaves the window". A GLYPH rather than a drawing: a diagonal is the one
		// shape a border box cannot be, and the svg the rest of these icons stopped being loses its right
		// and bottom edges under this engine`s `zoom` (measured - see the note in ui/workbench.css).
		mark := browser ? ` <span class="away">↗</span>` : ""

		state := ""
		title := fmt.tprintf("Nothing generated for %s in this format yet", name)
		if exists {
			state = "have"
			title = browser ? fmt.tprintf("Open %s in your browser", path) : fmt.tprintf("Show %s", path)
			if path != "" && path == app.shown_path {
				state = "have on"
				title = fmt.tprintf("%s — this is what the pane is showing", path)
			}
		}
		fmt.sbprintf(
			&b,
			`<button class="chip %s" data-open="%s"%s title="%s">%s%s</button>`,
			state,
			extensions[format],
			"" if exists else " disabled",
			escape_html(title, context.temp_allocator),
			tags[format],
			mark,
		)
	}
	sa.set_html(row, strings.to_string(b))
	set_shown(app, "#outputs", true)
}

// Open one named format for the selected scenario - the chip`s own file, rather than whichever output is
// newest. Same three destinations as everything else here: a cards page into the frame, text into the frame
// as text, a handviewer page into the browser.
open_output_format :: proc(app: ^App, extension: string) {
	if app.selected < 0 || app.selected >= len(app.scenarios) {
		return
	}
	name := app.scenarios[app.selected].name
	// The refusal is the model`s: `do_click` runs a disabled button`s behavior and the click arrives here
	// like any other, so a chip for a format that was never generated is turned away HERE.
	_, format, known := format_of_extension(fmt.tprintf("x%s", extension))
	if !known || format not_in formats_for(app, name) {
		set_status(app, fmt.tprintf("nothing generated for %s in that format yet", name))
		return
	}
	typed := strings.trim_space(read_text(app, "#outdir"))
	dir, abs_err := filepath.abs(typed, context.temp_allocator)
	if abs_err != nil {
		set_status(app, fmt.tprintf("deals folder: %q is not a usable path", typed))
		return
	}
	path, _ := filepath.join({dir, fmt.tprintf("%s%s", name, extension)}, context.temp_allocator)
	switch file_kind(path) {
	case .Cards:
		if show_page_file(app, path) {
			set_status(app, path)
		} else {
			set_status(app, "the hand page could not be loaded into the pane")
		}
	case .Handviewer:
		open_in_browser(path)
		set_status(app, fmt.tprintf("handviewer pages embed bridgebase.com — opened %s in your browser", path))
	case .Text:
		if show_text_file(app, path) {
			set_status(app, path)
		} else {
			set_status(app, fmt.tprintf("could not read %s", path))
		}
	}
}

// Show the selected scenario's output in the pane. `follow` says which of the two callers this is: the
// selection moving (which must not open the pane, and leaves a handviewer page alone), or a deliberate
// press. Resolved on every call rather than tracked, because the fields it depends on — the scenario, the
// output directory, the format — are all editable between one call and the next.
show_selected_page :: proc(app: ^App, follow: bool) {
	path, kind, found, why := selected_output(app)
	if !found {
		if !follow {
			set_status(app, why)
		}
		return
	}
	switch kind {
	case .Cards:
		// THE FOLLOW DOES NOT TAKE THE KEYBOARD. A page arriving because somebody pressed a chip or opened
		// the pane is a page they are about to read, so it gets the keys; a page arriving because the
		// SELECTION MOVED is a side effect of driving the list, and taking the caret out of the filter to
		// give it to the page is what made the arrows stop working after the first press.
		if !show_page_file(app, path, take_keyboard = !follow) {
			set_status(app, "the hand page could not be loaded into the pane")
		}
	case .Text:
		if !show_text_file(app, path) {
			set_status(app, fmt.tprintf("could not read %s", path))
		}
	case .Handviewer:
		if follow {
			// Deliberately nothing: see the block above. The `browser` button is on screen saying so.
			return
		}
		open_in_browser(path)
		set_status(app, fmt.tprintf("handviewer pages embed bridgebase.com — opened %s in your browser", path))
	}
}

/*
The file extension a format implies, for the per-scenario output path.

ONE EXTENSION PER FORMAT, and the reason is not tidiness: every text format used to write `<scenario>.txt`,
so generating a scenario as `pretty` and then as `line` OVERWROTE the first, and nothing could tell
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
	case "html-cards":
		return ".html"
	case "html-handviewer":
		// Its own extension, not `.html`: see FORMAT_EXTENSIONS. Sharing one meant the second of the two
		// formats generated silently replaced the first.
		return ".hv.html"
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

/*
Is this file something a BROWSER is the right answer for?

`open_in_browser` is a shell open, so it hands the file to whatever claims the extension: a `.txt` goes to
Notepad and a `.lin` to whichever bridge program registered it. Neither is a browser, and firing a file
association is not what a button labelled `browser` promises — so it is alive for a PAGE and nothing else,
and the pane can already show the rest as text.

By EXTENSION rather than by `file_kind`: both html formats are pages, and which of the two this is decides
where it opens, not whether it can.
*/
browsable_page :: proc(path: string) -> bool {
	return path != "" && strings.has_suffix(path, ".html") // covers `.hv.html` too
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
	set_shown(app, "#scnview", view == .Scenarios)
	set_shown(app, "#keyspanel", view == .Keys)
	set_shown(app, "#prefs-panel", view == .Prefs)
	if view in app.theme_stale {
		app.theme_stale -= {view}
		if root, err := sa.root(app.window); err == nil && root != nil {
			_ = sa.update_element(root, render = true)
		}
	}
	// Neither About nor the keys list is a tab, so neither disturbs the strip: both are entered from
	// anywhere and left by going back, and the strip should go on saying where "back" is.
	if view != .About && view != .Keys {
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
			{`.tab[data-view="scenarios"]`, .Scenarios},
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
	refresh_pane_segment(app)
}

/*
WHAT THE SEGMENT BEING ALIVE MEANS: there is a page to SHOW - which is not the same as one being loaded.

It used to mean the second, and that was wrong the moment `view page` stopped being a loader. A generate
run writes pages to DISK; it does not put one in the frame. So after pressing generate the segment stayed
dead, and with `view page` reduced to the browser hatch there was nothing left on screen that would load
one: a shut pane, a dead control, and a directory full of pages. A dead end, and the report of it is what
found this.

So the question the segment asks is the one `view page` used to ask on the click - does the SELECTED
scenario resolve to something this window can host - plus "or is one already in the frame". Which means it
is alive at STARTUP too, when the selected scenario has a page from an earlier session. Those deals may be
old, and that is fine: the page says which scenario it is and the status line says which file it came from.
Refusing to show a file that is sitting right there would be the worse answer.

A handviewer page does NOT count: hosting one is not something this window can do (it goes to the browser),
so a segment offering to put it in the pane would be offering something that cannot happen.
*/
page_available :: proc(app: ^App) -> bool {
	if app.page_ready {
		return true
	}
	_, kind, found, _ := selected_output(app)
	return found && kind != .Handviewer
}

// Enable or disable the three segments together. The whole group dims: a lit segment inside a dead group
// would claim the pane is open when there is nothing to open.
refresh_pane_segment :: proc(app: ^App) {
	available := page_available(app)
	for name in ([]string{"closed", "split", "wide"}) {
		set_enabled(app, fmt.tprintf(`.segbtn[data-pane="%s"]`, name), available)
	}
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

// WHERE THE HAND PAGE IS, as one value with three states rather than two independent toggles. A pane
// cannot be wide and shut, and two buttons said it could: `wide` on a closed pane had to open it and
// closing a wide pane had to un-widen it, corrections that existed only because the control was the wrong
// shape. Derived from the document, like everything else here — the enum is a reading of the display
// properties, not a second copy of them.
Pane_Mode :: enum {
	Closed,
	Split,
	Wide,
}

// Is what the pane is showing the selected scenario's output? Compared by NAME rather than by path, so a
// scenario whose page is in a folder the field has since been pointed away from is not mistaken for the
// current one. An in-memory page (no file) belongs to nothing and answers false.
shown_page_is_the_selection :: proc(app: ^App) -> bool {
	if !app.page_ready || app.shown_path == "" {
		return false
	}
	if app.selected < 0 || app.selected >= len(app.scenarios) {
		return false
	}
	base, _, ok := format_of_extension(filepath.base(app.shown_path))
	return ok && base == app.scenarios[app.selected].name
}

pane_mode :: proc(app: ^App) -> Pane_Mode {
	if !page_pane_shown(app) {
		return .Closed
	}
	return .Wide if pane_is_wide(app) else .Split
}

// The document's spelling of a mode, and the only place it is decoded — a `data-pane` on the segment, the
// same idiom the tab strip's `data-view` uses.
pane_mode_of :: proc(name: string) -> (mode: Pane_Mode, ok: bool) {
	switch name {
	case "closed":
		return .Closed, true
	case "split":
		return .Split, true
	case "wide":
		return .Wide, true
	}
	return .Closed, false
}

pane_mode_name :: proc(mode: Pane_Mode) -> string {
	switch mode {
	case .Closed:
		return "closed"
	case .Split:
		return "split"
	case .Wide:
		return "wide"
	}
	return "closed"
}

// Put the page where the pressed segment says. Every transition is expressible because the three states
// are one value: there is nothing to correct afterwards.
set_pane_mode :: proc(app: ^App, mode: Pane_Mode) {
	/*
	OPENING THE PANE SHOWS THE SELECTED SCENARIO. Two cases, and the second was reported.

	The frame may be EMPTY - after a generate run the pages are on disk and nothing has been put in the
	frame - and then this press is what fetches one. An empty pane would otherwise be the reward for
	pressing generate and asking to see the result.

	Or the frame may hold SOMEBODY ELSE'S page: the pane was closed, the selection moved (a closed pane is
	not followed, deliberately - see `note_selected_page`), and re-opening it brought back the file from
	before. The window then showed one scenario while the list, the chips and the status line all said
	another, with no chip lit because none of them was what was on screen ("the selected format button for
	a scenario needs a refresh when the hand page goes from hidden to shown, all options are still
	unselected"). So opening the pane re-asks the same question the follow asks.

	A page `analyse` built in memory is not a scenario's output and has no file, so it belongs to no
	scenario and is replaced too - the pane is a view of the deals view's selection whenever the deals view
	opens it.
	*/
	if mode != .Closed && !shown_page_is_the_selection(app) {
		show_selected_page(app, follow = false)
	}
	switch mode {
	case .Closed:
		show_page_pane(app, false)
	case .Split:
		set_pane_wide(app, false)
		show_page_pane(app, true)
	case .Wide:
		// GOING WIDE TAKES THE PICKER'S SPACE AWAY, so it is put away rather than left running behind a
		// page that covers it — otherwise it stays "open" with the report pane and the next CTRL+G would
		// close something nobody could see.
		set_tag_picker(app, false)
		set_pane_wide(app, true)
	}
	refresh_overlay_controls(app)
}

/*
The overlays live in `.work`, and `wide` hides `.work` — so while the page has the whole width there is
NOWHERE for the group picker or the keys list to be.

Reported: "the ctrl+g and ctrl+/ keys should not work if the hand page is fully open as cannot see the other
panel". They are refused rather than made to un-widen the pane first, which was the alternative: a key that
silently rearranges the window to make room for itself is doing two things, and this window already decided
that question when a list click was not allowed to change the shape of the view.

REFUSED OUT LOUD, THOUGH, and naming the key that fixes it — a control that does nothing and says nothing is
indistinguishable from one that is broken, which is the lesson of the CTRL+R report earlier today.
*/
overlays_have_room :: proc(app: ^App) -> bool {
	return pane_mode(app) != .Wide
}

// The `groups` button dims with the same rule, so the refusal is visible before it is pressed rather than
// only after. The MODEL still refuses too: `do_click` runs a disabled button's behavior and delivers the
// click like any other, so a button that only looked dead would still open the picker.
refresh_overlay_controls :: proc(app: ^App) {
	set_enabled(app, "#deal-groups", overlays_have_room(app))
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
show_page_pane :: proc(app: ^App, shown: bool, take_keyboard := true) {
	if shown && current_view(app) != .Panes {
		show_view(app, .Panes)
	}
	set_shown(app, "#pageview", shown)
	if !shown {
		set_shown(app, ".work", true)
	}
	apply_deal_layout(app)
	draw_deal_bar(app)
	// `take_keyboard = false` is the FOLLOW: a page that arrived because the selection moved must not take
	// the caret out of the field that moved it. See `focus_page`.
	if shown && take_keyboard {
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
	// Nothing to save first and nothing to restore after: the proportion is in the MODEL, which hiding a
	// pane does not touch (see `apply_deal_layout`).
	set_shown(app, ".work", !wide)
	apply_deal_layout(app)
	draw_deal_bar(app)
	remember_deals_layout(app)
}

/*
THE SPLIT'S WIDTHS - plain inline CSS on the panes, read and written in pane order.

It was a `<frameset>` and these went through the frame-set behavior's `state`; that was dropped (see the note
on `#deal-split` in the markup). Now a "state" is just the shown panes' inline `width`s, in order - the same
shape as before (`["250px", "1*", "2*"]`), so what the model renders and what a test sets mean what they did.
*/
DEAL_SPLIT_PANES :: 3 // the scenario list, the controls, the hand page

// The SHOWN panes of a split, in order: every child that is not a divider and not hidden.
split_panes :: proc(app: ^App, selector: string, allocator := context.temp_allocator) -> []sa.Element {
	split := find(app, selector)
	if split == nil {
		return nil
	}
	count, err := sa.child_count(split)
	if err != nil {
		return nil
	}
	panes := make([dynamic]sa.Element, 0, 4, allocator)
	for i in 0 ..< count {
		child := sa.child(split, i) or_continue
		if is_divider(child) {
			continue
		}
		if display, derr := sa.style(child, "display", context.temp_allocator); derr == nil && display == "none" {
			continue
		}
		append(&panes, child)
	}
	return panes[:]
}

is_divider :: proc(element: sa.Element) -> bool {
	classes, _ := sa.attribute(element, "class", context.temp_allocator)
	for word in strings.fields(classes, context.temp_allocator) {
		if word == "divider" {
			return true
		}
	}
	return false
}

read_split_state :: proc(app: ^App, allocator := context.allocator) -> []string {
	panes := split_panes(app, "#deal-split")
	widths := make([]string, len(panes), allocator)
	for pane, i in panes {
		value, _ := sa.style(pane, "width", allocator)
		widths[i] = value
	}
	return widths
}

write_split_state :: proc(app: ^App, widths: []string) -> bool {
	panes := split_panes(app, "#deal-split")
	if len(widths) == 0 || len(widths) != len(panes) {
		return false
	}
	for pane, i in panes {
		sa.set_style(pane, "width", widths[i])
	}
	return true
}

// The scenario list's on-screen width, 0 when it is not laid out.
list_width :: proc(app: ^App) -> i32 {
	element := find(app, "#scenario-list")
	if element == nil {
		return 0
	}
	box, err := sa.location(element, .Border, .Root)
	return err == nil ? box.width : 0
}

// The panes in the order the frameset holds them. The state array is positional and only counts the panes
// that are SHOWN, so this is the mapping between "the three widths worth remembering" and "the widths this
// frameset will accept right now".
DEAL_SPLIT_SELECTORS :: [DEAL_SPLIT_PANES]string{"#scenario-list", ".work", "#pageview"}



/*
SHOWING OR HIDING A PANE NEEDS THE FRAMESET RE-LAID OUT BY HAND.

Reported: closing the hand page left the controls at their old width with the freed half BLANK, and the
layout only caught up when something was clicked in the empty area. The `display: none` takes effect - the
pane is gone - but the frame-set behavior recomputes the widths of the panes it is left with on its own
schedule, and the next click is what happens to provide it. A window that looks broken until you poke it.

`update_element(el, render = true)` is the ask: style, layout and paint for that subtree, synchronously.
It is cheap here because the frameset has three children and the expensive one (a hand page of ~86MB) is
either being hidden or already laid out. Every show/hide of a pane goes through this, so there is one place
to look when a pane does not resize.
*/
relayout_split :: proc(app: ^App) {
	if element := find(app, "#deal-split"); element != nil {
		_ = sa.update_element(element, render = true)
	}
}

/*
THE DEALS VIEW'S LAYOUT IS A MODEL, RENDERED ONE WAY.

Reported twice, with screenshots, in two different shapes: panes squeezed to slivers after a drag, and the
controls stranded beside an empty column once the hand page was closed. Both came from the same place: the
widths lived in THREE places — the frameset's own state, a remembered copy of it, and the show/hide calls
that each patched one transition — and the frameset rewrites its state on its own (a hidden pane drops out of
it, a drag leaves pixels with no flexible pane). Every fix had been one more patch between two of them.

So the widths are ONE value, `app.deal_layout`, and `apply_deal_layout` derives the frameset from it and from
which panes are shown, every time anything changes — show, hide, wide, startup. It never reads the frameset
back. The single reverse flow is the end of a drag (`take_deal_drag`), which updates the MODEL from what the
drag did and then renders again.

The list and the controls are FIXED CSS-px widths and the hand page takes the rest (`1*`) — a sidebar-and-
content layout, so a window resize grows the page and leaves the controls alone. They were flex SHARES once
(`1487*` : `835*`), and the real window's drag log showed this engine does not honour shares as a proportion:
its flex units divide the space LEFT AFTER each pane's content ("Flex units distribute free space left in a
container after applying length units to content" - the SDK's flows-and-flexes.md), and a hand page claims
nearly all of it. The release re-render then left the controls 28px wide. The drag itself always wrote a fixed
width plus `1*`, and that always looked right - so that is what the model renders too.

The controls' width is CLAMPED when rendered (`work_width_px`), so the list and the controls always leave the
page some of the window: px is what zoom scales, and an unclamped px layout is what overflowed the window at
150% before. Until a first drag the controls have no width of their own and the document's 1:2 stands.
*/
Deal_Layout :: struct {
	list_px: int, // CSS px, the zoom applied on top
	work_px: int, // CSS px; 0 = not dragged yet, use the 1:2 default
}

DEFAULT_DEAL_LAYOUT :: Deal_Layout{250, 0}

// Never squeeze the page below this many CSS px to honour a remembered controls width.
DEAL_PAGE_MIN_PX :: 200

// The model, or the default when there is none (a fresh App, a test, an unreadable pref).
deal_layout :: proc(app: ^App) -> Deal_Layout {
	l := app.deal_layout
	if l.list_px <= 0 {
		l.list_px = DEFAULT_DEAL_LAYOUT.list_px
	}
	if l.work_px < 0 {
		l.work_px = 0
	}
	return l
}

// The controls' width to RENDER: the remembered one, but never so wide that the page is left less than
// `DEAL_PAGE_MIN_PX` of the split (or so narrow it is unusable). In CSS px; the split is measured on screen.
work_width_px :: proc(app: ^App, l: Deal_Layout, list_on: bool) -> int {
	split := find(app, "#deal-split")
	if split == nil {
		return l.work_px
	}
	box, err := sa.location(split, .Border, .Root)
	if err != nil || box.width <= 0 {
		return l.work_px
	}
	room := int(f64(box.width) / zoom_factor(app)) - DEAL_PAGE_MIN_PX - 12 // the dividers
	if list_on {
		room -= l.list_px
	}
	return clamp(l.work_px, 150, max(room, 150))
}

apply_deal_layout :: proc(app: ^App, loc := #caller_location) {
	l := deal_layout(app)
	list_on := scenario_list_shown(app)
	work_on := !effective_display_is_hidden(app, ".work")
	page_on := page_pane_shown(app)
	widths := make([dynamic]string, 0, DEAL_SPLIT_PANES, context.temp_allocator)
	if list_on {
		append(&widths, fmt.tprintf("%dpx", l.list_px))
	}
	// A pane alone beside the list takes ALL the rest (`1*`). With both, the controls have their fixed width
	// and the page the rest - or, before any drag, the document's own 1:2.
	if work_on {
		switch {
		case !page_on:
			append(&widths, "1*")
		case l.work_px > 0:
			append(&widths, fmt.tprintf("%dpx", work_width_px(app, l, list_on)))
		case:
			append(&widths, "1*")
		}
	}
	if page_on {
		append(&widths, "2*" if work_on && l.work_px <= 0 else "1*")
	}
	show_needed_dividers(app, "#deal-split")
	if len(widths) > 0 {
		_ = write_split_state(app, widths[:])
	}
	drag_log(app, fmt.tprintf("apply %v from %s:%d (model %v)", widths[:], loc.procedure, loc.line, l))
	relayout_split(app)
}

// A line in the DRAG LOG — the script's console, so the host's half lands beside the script's half in the
// order they happened. Debug builds only, like the log itself; see `WB_DRAG_LOG` in the document.
drag_log :: proc(app: ^App, line: string) {
	when ODIN_DEBUG {
		escaped, _ := strings.replace_all(line, `"`, `'`, context.temp_allocator)
		if result, err := sa.eval(app.window, fmt.tprintf(`wbDragLog("host %s")`, escaped)); err == nil {
			sa.value_clear(&result)
		}
	}
}

/*
A DIVIDER IS SHOWN ONLY BETWEEN TWO SHOWN PANES.

A hidden pane takes its divider with it: walking the split's children in order, a divider stays only when a
shown pane comes before it AND after it, and never two in a row. Without this a closed pane left a stray line
at the window's edge (reported, in two screenshots). Plain `display: none` is fine for these: they are
ordinary elements now, not a frameset's splitters (which that broke).
*/
show_needed_dividers :: proc(app: ^App, selector: string) {
	split := find(app, selector)
	if split == nil {
		return
	}
	count, err := sa.child_count(split)
	if err != nil {
		return
	}
	pending: sa.Element // a divider with a shown pane before it, waiting to see if one comes after
	pane_before := false
	for i in 0 ..< count {
		child := sa.child(split, i) or_continue
		if is_divider(child) {
			sa.set_style(child, "display", "none")
			if pane_before && pending == nil {
				pending = child
			}
			continue
		}
		if display, derr := sa.style(child, "display", context.temp_allocator); derr == nil && display == "none" {
			continue // a hidden pane: neither side of it counts
		}
		if pending != nil {
			sa.set_style(pending, "display", "block")
			pending = nil
		}
		pane_before = true
	}
}

/*
A drag of one of the deals view's dividers ended: REMEMBER WHAT IT WROTE, then render from the model.

Read, not calculated: the drag script writes the two panes beside the divider as plain CSS (`1487px`), so the
panes' own inline widths ARE the new layout, in the model's units. Nothing is measured — on release the layout
can still be catching up with the last moves (a 48-board hand page re-lays out in ~124ms a step), and a
measurement then reads where the panes WERE, which snapped the divider back. A width the drag did not touch is
read back unchanged, so reading every pane is safe.
*/
take_deal_drag :: proc(app: ^App) {
	l := deal_layout(app)
	if scenario_list_shown(app) {
		if px, ok := inline_px(app, "#scenario-list"); ok {
			l.list_px = px
		}
	}
	// The controls' width only while the page is beside them: with the page shut they are the last pane and
	// `1*`, which is not a width of their own.
	if page_pane_shown(app) && !effective_display_is_hidden(app, ".work") {
		if px, ok := inline_px(app, "#work"); ok {
			l.work_px = px
		}
	}
	app.deal_layout = l
	drag_log(app, fmt.tprintf("release -> model %v", l))
	apply_deal_layout(app)
}

// An element's inline width when it is a px length (`1487px` -> 1487); not ok for `1*` or nothing.
inline_px :: proc(app: ^App, selector: string) -> (px: int, ok: bool) {
	element := find(app, selector)
	if element == nil {
		return 0, false
	}
	value, err := sa.style(element, "width", context.temp_allocator)
	if err != nil || !strings.has_suffix(value, "px") {
		return 0, false
	}
	parsed := strconv.parse_f64(strings.trim_suffix(value, "px")) or_return
	if parsed <= 0 {
		return 0, false
	}
	return int(parsed + 0.5), true
}

// The model as a pref, and back: `250px,1487px` (list, controls; `0px` = not dragged). Anything else — an
// older build's three-entry layout included — is the default.
deal_layout_text :: proc(l: Deal_Layout) -> string {
	return fmt.tprintf("%dpx,%dpx", l.list_px, l.work_px)
}

parse_deal_layout :: proc(text: string) -> (l: Deal_Layout, ok: bool) {
	parts := strings.split(text, ",", context.temp_allocator)
	if len(parts) != 2 {
		return {}, false
	}
	list := strings.trim_space(parts[0])
	work := strings.trim_space(parts[1])
	if !strings.has_suffix(list, "px") || !strings.has_suffix(work, "px") {
		return {}, false
	}
	list_px := strconv.parse_int(strings.trim_suffix(list, "px")) or_return
	work_px := strconv.parse_int(strings.trim_suffix(work, "px")) or_return
	if list_px <= 0 || work_px < 0 {
		return {}, false
	}
	return Deal_Layout{list_px, work_px}, true
}

show_scenario_list :: proc(app: ^App, shown: bool) {
	set_shown(app, "#scenario-list", shown)
	apply_deal_layout(app)
	draw_deal_bar(app)
	remember_deals_layout(app)
}

// The lit segment says where the page IS. That is the opposite of what the two buttons this replaced did
// (their labels named the NEXT PRESS, because a lone toggle has nowhere to show its state) and it is the
// reason a three-position control is worth the markup: with every state on screen at once, showing which
// one is current says more than any label could.
//
// Read from the document, written to the document. `pane_mode` derives the answer from the display
// properties, so the lit segment cannot drift from where the page actually is.
draw_deal_bar :: proc(app: ^App) {
	mode := pane_mode(app)
	for name in ([]string{"closed", "split", "wide"}) {
		element := find(app, fmt.tprintf(`.segbtn[data-pane="%s"]`, name))
		if element == nil {
			continue
		}
		lit := name == pane_mode_name(mode)
		_ = sa.set_attribute(element, "class", "segbtn on" if lit else "segbtn")
	}
}

// The layout, remembered across sessions. Three booleans in the host prefs file beside the zoom - the same
// place and for the same reason: they belong to the person rather than to the document.
DEALS_PANE_PREF :: "deals.pane"
DEALS_WIDE_PREF :: "deals.wide"
DEALS_LIST_PREF :: "deals.list"
DEALS_SPLIT_PREF :: "deals.split"

remember_deals_layout :: proc(app: ^App) {
	if app.prefs_path == "" {
		return // no prefs file yet (a test app); the layout is still whatever the document says
	}
	prefs.set(&app.prefs, DEALS_PANE_PREF, page_pane_shown(app) ? "open" : "closed")
	prefs.set(&app.prefs, DEALS_WIDE_PREF, pane_is_wide(app) ? "wide" : "with-controls")
	prefs.set(&app.prefs, DEALS_LIST_PREF, scenario_list_shown(app) ? "open" : "closed")
	prefs.set(&app.prefs, DEALS_SPLIT_PREF, deal_layout_text(deal_layout(app)))
	_ = prefs.save(&app.prefs, app.prefs_path)
}

// And restored at startup. The PANE is not restored open: there is nothing in it until something has been
// generated or analysed, and an empty pane beside the controls would be a promise the window cannot keep.
restore_deals_layout :: proc(app: ^App) {
	if remembered, found := prefs.get(&app.prefs, DEALS_LIST_PREF); found {
		show_scenario_list(app, remembered != "closed")
	}
	// The SPLIT is restored though the pane is not: the proportion is what someone dragged, and a window
	// that opens with the columns where they left them is the point of remembering it at all. It is applied
	// whether or not the pane is open, because the two panes still in the frameset take the share the
	// remembered array gives them.
	if remembered, found := prefs.get(&app.prefs, DEALS_SPLIT_PREF); found {
		if layout, ok := parse_deal_layout(remembered); ok {
			app.deal_layout = layout
		}
	}
	apply_deal_layout(app)
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
	case "scenarios":
		return .Scenarios, true
	}
	return .Panes, false
}

// Which view is on screen. Read from the document rather than remembered — same reason as
// `effective_display_is_hidden`.
current_view :: proc(app: ^App) -> View {
	if !effective_display_is_hidden(app, "#about-panel") {
		return .About
	}
	// BEFORE the editor's, and a view added here MUST be added here: a member missing from this chain does
	// not fail, it silently reads as `.Panes` — which is how the keys list came to remember the wrong place
	// to go back to (open it from the notes view, press escape, arrive in the deals view).
	if !effective_display_is_hidden(app, "#keyspanel") {
		return .Keys
	}
	if !effective_display_is_hidden(app, "#prefs-panel") {
		return .Prefs
	}
	if !effective_display_is_hidden(app, "#editview") {
		return .Editor
	}
	if !effective_display_is_hidden(app, "#scnview") {
		return .Scenarios
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
show_page_html :: proc(app: ^App, html: string, title: string, take_keyboard := true) -> bool {
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
	remember_shown_path(app, "") // built here, not read from disk: no chip owns it
	apply_page_zoom(app) // a new document is a new root, unzoomed or at the window's zoom — not the page's
	set_text_at(app, "#page-title", title)
	page_ready(app, true)
	// The pane OPENS itself when a page arrives: pressing generate and then having to press something else
	// to see the result is a step with no decision in it. Closing it stays a decision.
	show_page_pane(app, true, take_keyboard)
	return true
}

// The same, for a page a generate run wrote. `loadFile` rather than reading the file here: the engine
// resolves the path, and a page too big to want in memory twice is exactly what a batch produces.
show_page_file :: proc(app: ^App, path: string, take_keyboard := true) -> bool {
	asset := page_frame_asset(app) or_return
	path_value := sa.value_from(path)
	defer sa.value_clear(&path_value)

	result, err := sa.asset_call(asset, "loadFile", {path_value})
	defer sa.value_clear(&result)
	if err != nil || sa.value_is_error(&result) {
		return false
	}
	remember_shown_path(app, path)
	apply_page_zoom(app)
	set_text_at(app, "#page-title", path)
	page_ready(app, true)
	show_page_pane(app, true, take_keyboard)
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
focus_page :: proc(app: ^App, force := false) {
	// AND IT NEVER TAKES THE CARET OUT OF THE FILTER. Reported: "ctrl+r select scenario filter ok, on
	// pressing down the filter is deselected". The follow already passes `take_keyboard = false` for the
	// case that produced it, and this is the general form of the same rule — a page appearing must not
	// interrupt somebody who is TYPING, whatever route it arrived by. Two guards for one bug because they
	// fail differently: the parameter is exact and covers the known path, this covers the ones not written
	// yet, and neither depends on the other being right.
	// `force` is the SWAP KEY asking for it on purpose. The guard below is about a page ARRIVING while
	// somebody types; being asked to go to the page is the opposite of that.
	if !force && scenario_filter_has_focus(app) {
		return
	}
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
// Package-visible, not file-private: the SCENARIO editor sends the same shape of payload to the same
// script function, and a second copy of json escaping is a second place to get an escape wrong.
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
	if te, ok := sa.timer_event(event); ok && te.id == PAGE_FOLLOW_TIMER {
		// The hand page's follow debounce. POSTED for exactly the reason spelled out below for the preview's:
		// the load replaces this frame's document, and rebuilding it from inside the frame's own dispatch
		// tears the tree out from under the engine. `false` stops the timer — a one-shot the next arrow
		// press re-arms.
		sa.post_callback(app.window, FOLLOW)
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
	if be, ok := sa.behavior_event(event); ok && be.code == .DOCUMENT_COMPLETE && handler == &app.page_handler {
		// THE HAND PAGE'S document is done: give it the page zoom. Reported as the zoom being forgotten when
		// flipping from a text format back to the cards page — `loadFile` returns before its document exists,
		// so the zoom `show_page_file` applies lands on the OLD one. Setting a style is not a document
		// replacement, so doing it inside the frame's own dispatch is safe (unlike a render). Not claimed.
		apply_page_zoom(app)
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
	if !show_page_html(app, document, path) {
		return false
	}
	// `show_page_html` clears the shown path - it is for a page built in memory, which no chip owns - and
	// this document IS built in memory, but it is a VIEW OF A FILE. So the path goes back on afterwards,
	// or a text output could never be the lit chip.
	remember_shown_path(app, path)
	return true
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
		// A PANE OF A SPLIT takes its divider with it: every show/hide in the window comes through here, so
		// the dividers follow the panes in all three views without any caller having to remember them.
		if parent, perr := sa.parent(element); perr == nil && parent != nil {
			if classes, _ := sa.attribute(parent, "class", context.temp_allocator); strings.contains(classes, "split") {
				if id, _ := sa.attribute(parent, "id", context.temp_allocator); id != "" {
					show_needed_dividers(app, fmt.tprintf("#%s", id))
				}
			}
		}
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

Written on every keyboard step AND every wheel step. The wheel is a script event, so the script posts
`wb-zoom` after it zooms and the host saves the factor it reads back. Until it did, a window zoomed with the
wheel opened at 100% again the next time - reported, after "a scale that survives most of the time" had been
judged good enough here.
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

/*
THE HAND PAGE'S OWN ZOOM — see the script's note in `ui/workbench.html` for the two measured facts behind it.
The factor lives in the script (the wheel over the page is a script event, like the window's), and these
are the host's ways in: the page bar's buttons, a page load, and the remembered value at startup.
*/
PAGE_ZOOM_PREF :: "page.zoom"

page_zoom_step :: proc(app: ^App, direction: int) {
	result, err := sa.eval(app.window, fmt.tprintf("wbPageZoomStep(%d)", direction))
	defer sa.value_clear(&result)
	if err != nil {
		log.warnf("the page zoom did not change: %v", err)
		return
	}
	factor, ferr := sa.value_to_f64(&result)
	if ferr != nil {
		return
	}
	set_status(app, fmt.tprintf("hand page %d%%", int(factor * 100 + 0.5)))
	remember_page_zoom(app, factor)
}

remember_page_zoom :: proc(app: ^App, factor: f64) {
	if app.prefs.values != nil {
		prefs.set(&app.prefs, PAGE_ZOOM_PREF, fmt.tprintf("%.2f", factor))
		if app.prefs_path != "" {
			_ = prefs.save(&app.prefs, app.prefs_path)
		}
	}
}

// The page's factor as the script has it (the wheel changes it without telling this side the number).
page_zoom_factor :: proc(app: ^App) -> f64 {
	result, err := sa.eval(app.window, "WB_PAGE_ZOOM")
	defer sa.value_clear(&result)
	if err != nil {
		return 1
	}
	factor, ferr := sa.value_to_f64(&result)
	return ferr == nil ? factor : 1
}

// Re-apply the page's factor to whatever document the frame now holds.
apply_page_zoom :: proc(app: ^App) {
	result, _ := sa.eval(app.window, "wbApplyPageZoom()")
	sa.value_clear(&result)
}

// What a first start gets, before anything is remembered. Deliberately ABOVE 100% for now (asked for: a
// zoomed window is where the layout bugs have been, so it is the state worth living in), and a choice rather
// than a fixed fact — change these two and the remembered values still win.
DEFAULT_ZOOM :: 1.21 // two steps in: 1.1 x 1.1, the same place two presses of ctrl+plus land
DEFAULT_PAGE_ZOOM :: 1.10

restore_page_zoom :: proc(app: ^App) {
	factor := DEFAULT_PAGE_ZOOM
	if remembered, found := prefs.get(&app.prefs, PAGE_ZOOM_PREF); found {
		if parsed, ok := strconv.parse_f64(remembered); ok && parsed > 0 {
			factor = parsed
		}
	}
	result, _ := sa.eval(app.window, fmt.tprintf("wbSetPageZoom(%f)", factor))
	sa.value_clear(&result)
}

// Put back what was remembered, once the document is up (the scale lives on its root element).
restore_zoom :: proc(app: ^App) {
	factor := DEFAULT_ZOOM
	remembered, found := prefs.get(&app.prefs, ZOOM_PREF)
	if found {
		if parsed, ok := strconv.parse_f64(remembered); ok && parsed > 0 {
			factor = parsed
		}
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
/*
THE SCENARIO FILTER: type in the bar, and the list is what you named.

WHY. The registry is a hundred entries and a row is two lines tall, so the list is several screens of
names that all begin `1c-` or `2d-`. The scrollbar is the wrong instrument for that: what somebody knows
is the NAME of the auction they want, and the one thing the list would not let them do is say it.

THE MATCHING IS THE HEADING PALETTE'S, `outline.score_name` with nothing added. It is a subsequence match
where the query's spaces and punctuation are SEPARATORS rather than characters, which is what makes `1c 2h`
find `1c-any-2h-or-2n`: the registry spells its auctions with dashes and nobody types dashes. That rule
was written for the notes (`1h 1s` against `1H-1S`, `1H--1S` and `1H/1S`, which the corpus spells all three
ways) and the problem here is the same one, so it is the same code and not a second dialect of it.

THE INDICES STAY REGISTRY INDICES. `app.selected` indexes `bidding.registry` and a row carries that number
in `data-index`, filtered or not - so the click handler, the chips, `selected_output` and the generate job
all go on meaning what they meant, and the filter is a projection of the list and nothing more. Making
`selected` an index into the VISIBLE rows instead is the obvious shortcut and it silently re-points every
one of those the moment a query is typed.
*/

// A scenario the query matched, and how well. `by_name` is not part of the score: it PARTITIONS.
@(private = "file")
Scenario_Match :: struct {
	index:   int,
	score:   int,
	by_name: bool,
}

/*
The registry indices the filter leaves, in the order to draw them.

WITH NO QUERY this is the registry, in registry order — which is an order somebody chose ("roughly as the
bidding develops": opener, then responses, then competition) and is the right thing to see when nothing has
been asked for.

WITH A QUERY the name is matched first and the DESCRIPTION second, and a name hit always outranks a
description hit rather than merely scoring above it. The description is worth searching — it is where
`Marmic`, `Swedish club` and `South responds` are, none of which the terse names contain — but it is also
fifty characters of prose, and a short query is a subsequence of nearly any fifty characters. Scored
together the prose would drown the names; partitioned, the names are the top of the list and the prose is
the tail you scroll to when you meant it.
*/
visible_scenarios :: proc(app: ^App, allocator := context.allocator) -> []int {
	query := read_text(app, "#scenario-filter")
	shown := make([dynamic]int, 0, len(app.scenarios), allocator)
	// `is_blank_query` rather than `trim_space`, for the same reason the palette uses it: a query of
	// nothing but punctuation names nothing, and so excludes nothing.
	// THE GROUPS WIDEN, THE TYPING NARROWS, and this is the one place both are applied. An empty selection
	// is not a filter at all (`has_any_tag` says so), so the common state costs nothing and needs no case.
	wanted := selected_tag_names(app, context.temp_allocator)
	if outline.is_blank_query(query) {
		for _, i in app.scenarios {
			if in_selected_groups(app, i, wanted) {
				append(&shown, i)
			}
		}
		return shown[:]
	}

	trimmed := strings.trim_space(query)
	matches := make([dynamic]Scenario_Match, 0, len(app.scenarios), context.temp_allocator)
	for scenario, i in app.scenarios {
		if !in_selected_groups(app, i, wanted) {
			continue // the groups decide WHICH scenarios are in play; the query only ranks them
		}
		if points, hit := outline.score_name(trimmed, scenario.name); hit {
			append(&matches, Scenario_Match{index = i, score = points, by_name = true})
			continue
		}
		if points, hit := outline.score_name(trimmed, scenario.description); hit {
			append(&matches, Scenario_Match{index = i, score = points, by_name = false})
		}
	}
	// STABLE, so that two equally good matches keep registry order and the row under the selection does not
	// swap with its neighbour between one keystroke and the next.
	slice.stable_sort_by(matches[:], proc(a, b: Scenario_Match) -> bool {
		if a.by_name != b.by_name {
			return a.by_name
		}
		return a.score > b.score
	})
	for match in matches {
		append(&shown, match.index)
	}
	return shown[:]
}

/*
THE SCENARIO GROUPS: which sets the list is drawn from.

WHY TAGS AND NOT A FOLDER. A scenario belongs to more than one thing at once — `defence-vs-high-preempts`
is honestly basic, competitive AND a preempt — so a tree with one home per scenario would have to pick a
lie. The membership lives in `bidding/tags.odin` beside the scenarios it describes; what is here is the
selection and the drawing.

SELECTED GROUPS COMBINE WITH *OR*, AND THAT IS NEVER OFFERED AS A CHOICE. Two groups intersected is a
near-empty list nobody asked for; picking two groups means wanting to see both. So the rule for the whole
view is one sentence — THE GROUPS WIDEN AND THE TYPING NARROWS — and an AND/OR switch is exactly the thing
that would break it, by making somebody hold a boolean model to predict their own list.

THE CHIPS ARE IN THE BAR, NOT IN `.outputs`, and that is not arbitrary. The format chips a few pixels away
mean "a file that exists, press to open"; these mean "a filter, press to remove". Same shape, opposite
sense, so they get a different place (beside the text filter they compose with) and a different affordance
(the ×, which the format chips have not got). And they are drawn ONLY when something is selected: no groups
is the common state and it should cost no room and say nothing.
*/

/*
LOAD THE USER'S OWN SCENARIOS, and build the registry and the group list from what came back.

WHERE IT LOOKS is `BRIDGE_SCENARIOS` (`;`-separated, the same variable `sim` reads) plus whatever is
remembered in the host prefs. Nothing here invents a default directory: a scenario file is a thing
somebody chose to write somewhere, and guessing at `~/.bridge/scenarios` would be this program having an
opinion about a person's filesystem.

COMPILED FIRST, LOADED SECOND, the same order `sim` uses and for the same reason: `cli.lookup` takes the
first exact match, so a compiled scenario wins a name clash and a user file cannot silently redefine
`1c-any` out from under the recipes and the pages already on `w:/deals/`.

SAFE WITH NOTHING CONFIGURED, which is the normal case: no directories means no files, an empty `Loaded`,
and a registry that is exactly `bidding.registry` — the window behaves as it did before any of this.
*/
load_user_scenarios :: proc(app: ^App) {
	scenario_dsl.set_vocabulary(bidding.vocabulary)

	// ONE ENTRY PER FOLDER, however many places name it: the environment and the pref can both hold the
	// same folder (spelled with different slashes, even), and reading it twice would load every scenario
	// in it twice — two identical rows, and a sources list counting the folder twice.
	directories := make([dynamic]string, 0, 4, app.allocator)
	add := proc(directories: ^[dynamic]string, list: string, allocator: runtime.Allocator) {
		for part in strings.split(list, ";", context.temp_allocator) {
			trimmed := strings.trim_space(part)
			if trimmed == "" {
				continue
			}
			for already in directories {
				if same_dir(already, trimmed) {
					trimmed = ""
					break
				}
			}
			if trimmed != "" {
				append(directories, strings.clone(trimmed, allocator))
			}
		}
	}
	add(&directories, os.get_env("BRIDGE_SCENARIOS", context.temp_allocator), app.allocator)
	if remembered, found := prefs.get(&app.prefs, SCENARIO_DIRS_PREF); found {
		add(&directories, remembered, app.allocator)
	}
	app.scenario_dirs = directories[:]
	app.loaded = scenario_dsl.load_directories(app.scenario_dirs, app.allocator)

	registry := make([dynamic]cli.Scenario, 0, len(bidding.registry) + len(app.loaded.scenarios), app.allocator)
	append(&registry, ..bidding.registry)
	append(&registry, ..app.loaded.scenarios)
	app.scenarios = registry[:]

	build_groups(app)
}

// Startup's first two reads, IN THIS ORDER and in one place so a test can hold them to it: the prefs file,
// then the scenario folders it names. The other way round was a shipped bug — see the comment in `main`.
// Takes ownership of `prefs_path`.
load_prefs_and_scenarios :: proc(app: ^App, prefs_path: string) {
	app.prefs_path = prefs_path
	app.prefs = prefs.load(app.prefs_path, app.allocator)
	load_user_scenarios(app)
}

/*
Give back everything `load_user_scenarios` took, so it can be called again.

THE ORDER MATTERS and it is the reason this is a procedure rather than four lines at the call site: the
concatenated registry POINTS INTO `app.loaded` (an interpreted scenario's condition carries a `^Program`),
so the registry goes first and the programs after it. The other way round leaves a slice of scenarios
whose conditions point at freed memory, for as long as it takes the next line to run.

`app.groups` is not freed here: `build_groups` frees the list it replaces, so it is owned by the one
procedure that builds it.
*/
free_user_scenarios :: proc(app: ^App) {
	delete(app.scenarios, app.allocator)
	app.scenarios = nil
	scenario_dsl.destroy_loaded(&app.loaded, app.allocator)
	for directory in app.scenario_dirs {
		delete(directory, app.allocator)
	}
	delete(app.scenario_dirs, app.allocator)
	app.scenario_dirs = nil
}

// Where the user's scenario directories are remembered, `;`-separated like the environment variable.
SCENARIO_DIRS_PREF :: "scenarios.dirs"

/*
A GROUP, from either source.

`bidding.tags` is the compiled system's vocabulary and is editorial: somebody decided that
`swedish-club` and `competitive` are the axes worth having. A `.scenario` file may declare tags of its
own, and those are equally real — a user who writes `tags: mine` has made a group, and one with no row in
the picker would be a group nobody could select. So the two are merged and `from_files` records which is
which, because "this group came from your files" is worth saying on the row.
*/
Group :: struct {
	name:        string,
	description: string,
	from_files:  bool,
}

/*
Build the merged group list: the compiled vocabulary, then any tag a loaded scenario declared that is not
already in it.

ORDER IS COMPILED-FIRST and stable, because the picker's DIGITS are positions: `1` must not become a
different group because a file appeared in a directory. New groups are appended in the order they are
first seen, so adding a scenario file cannot renumber the ones already there.
*/
build_groups :: proc(app: ^App) {
	groups := make([dynamic]Group, 0, len(bidding.tags) + 4, app.allocator)
	for tag in bidding.tags {
		append(&groups, Group{name = tag.name, description = tag.description, from_files = false})
	}
	for tags in app.loaded.tags {
		for tag in tags {
			known := false
			for existing in groups {
				if existing.name == tag {
					known = true
					break
				}
			}
			if !known {
				append(&groups, Group{name = tag, description = "from your scenario files", from_files = true})
			}
		}
	}
	// FREED BEFORE IT IS REPLACED, because `reload_scenarios` calls this a second time. The Group VALUES
	// borrow their strings from `bidding.tags` and from the loaded scenarios' own tags, so only the slice
	// is ours to free — the tag strings belong to `app.loaded` and go when it is destroyed.
	if app.groups != nil {
		delete(app.groups, app.allocator)
	}
	app.groups = groups[:]
	// The flags are parallel to the groups, so they are rebuilt with them. A reload cannot leave a
	// selection pointing at a group that has gone.
	if app.tag_on != nil {
		delete(app.tag_on, app.allocator)
	}
	app.tag_on = make([]bool, len(app.groups), app.allocator)
}

/*
The groups a scenario belongs to, BY INDEX into `app.scenarios`.

By index rather than by name, and that is the whole reason this proc exists instead of a call to
`bidding.tags_for`: the registry is a concatenation, and a loaded scenario may share a name with a
compiled one. An index says which of the two is being asked about; a name cannot.
*/
scenario_groups :: proc(app: ^App, index: int) -> []string {
	compiled := len(bidding.registry)
	if index >= compiled {
		loaded_at := index - compiled
		if loaded_at < len(app.loaded.tags) {
			return app.loaded.tags[loaded_at]
		}
		return nil
	}
	if index < 0 || index >= len(app.scenarios) {
		return nil
	}
	return bidding.tags_for(app.scenarios[index].name)
}

// Does this scenario carry any of the selected groups? The OR in "the groups widen": an empty selection
// is not a filter at all, which is what makes "no group" mean "all of them".
in_selected_groups :: proc(app: ^App, index: int, wanted: []string) -> bool {
	if len(wanted) == 0 {
		return true
	}
	carried := scenario_groups(app, index)
	for want in wanted {
		for tag in carried {
			if tag == want {
				return true
			}
		}
	}
	return false
}

// The names of the selected groups, for `in_selected_groups`. Empty when nothing is selected, which is
// what makes "no group" mean "all of them".
selected_tag_names :: proc(app: ^App, allocator := context.allocator) -> []string {
	names := make([dynamic]string, 0, len(app.groups), allocator)
	for tag, i in app.groups {
		if i < len(app.tag_on) && app.tag_on[i] {
			append(&names, tag.name)
		}
	}
	return names[:]
}

// How many scenarios a group holds, for the picker's rows. What tells somebody a group is worth selecting
// BEFORE they select it — a row that turns out to name three scenarios is a wasted press otherwise.
tag_population :: proc(app: ^App, name: string) -> (count: int) {
	only := []string{name}
	for _, i in app.scenarios {
		if in_selected_groups(app, i, only) {
			count += 1
		}
	}
	return
}

// Turn one group on or off, from the picker or from a chip's ×. Everything that can change the visible set
// funnels through here, so the list, the chips and the repaired selection cannot disagree.
toggle_tag :: proc(app: ^App, index: int) {
	if index < 0 || index >= len(app.tag_on) {
		return
	}
	app.tag_on[index] = !app.tag_on[index]
	render_groups(app)
}

// EVERYTHING THE GROUP FLAGS DECIDE, drawn from them in one call: the chips, the picker's ticks, and the list
// they filter (which also repairs the selection). Every change to `tag_on` ends here, so no caller can redraw
// two of the three and leave the third showing the old groups.
render_groups :: proc(app: ^App) {
	draw_tag_chips(app)
	draw_tag_picker(app)
	filter_scenarios(app)
}

// Every group off: what the last chip's × leaves behind, and what backspace in the picker does.
clear_tags :: proc(app: ^App) {
	for i in 0 ..< len(app.tag_on) {
		app.tag_on[i] = false
	}
	render_groups(app)
}

// The chips: one per SELECTED group, each carrying the × that removes it. Absent entirely when nothing is
// selected — an empty container still takes its margins in this engine, so the element is hidden rather
// than merely emptied.
draw_tag_chips :: proc(app: ^App) {
	row := find(app, "#tagchips")
	if row == nil {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	any := false
	for tag, i in app.groups {
		if i >= len(app.tag_on) || !app.tag_on[i] {
			continue
		}
		any = true
		// THE WHOLE CHIP IS THE REMOVE TARGET and the × says so. A hit area the size of the glyph alone is
		// a control only a mouse can use well, and this window is meant to be driveable without one.
		fmt.sbprintf(
			&b,
			`<div class="tagchip" data-untag="%d" title="Stop filtering by %s">%s<span class="x">×</span></div>`,
			i,
			escape_html(tag.name, context.temp_allocator),
			escape_html(tag.name, context.temp_allocator),
		)
	}
	sa.set_html(row, strings.to_string(b))
	set_shown(app, "#tagchips", any)
	// THE BUTTON SAYS IT TOO. The chips are the detailed answer, but the bar is a row that can get cramped
	// and they are the part that would be squeezed out of it; the button is fixed-width and always there,
	// so it is what carries "this list is narrowed" when there is no room for what to.
	if button := find(app, "#deal-groups"); button != nil {
		_ = sa.set_attribute(button, "class", "ghost icon-text on" if any else "ghost icon-text")
	}
}

/*
THE PICKER (CTRL+G), IN THE REPORT PANE'S PLACE.

WHERE IT GOES. At startup `#report` holds one sentence and is otherwise the largest empty box in the
window, so the picker takes that space and gives it back on close. It is a SIBLING of `#report` in `.work`
and swaps `display` with it — NOT an overlay: an out-of-flow percentage height lays out 1px tall in this
engine (the same fact that makes the heading palette a row in the editor's flow rather than a floating
box), so a floating picker is a bug waiting to be written. It reads as modal because it covers a region and
takes the keys, which is what modal is for here.

IT CLOSES WHEN A RUN STARTS. During a batch the transcript is the thing worth looking at, and a picker left
sitting over it is the same failure as a segment that stayed dead after generate: the window showing the
wrong thing because nobody told it the situation had changed.

WHY A PALETTE AND NOT CHECKBOXES. A checkbox list is a mouse control a keyboard can reach; this is a
keyboard control a mouse can click, which is the way round that was asked for. The number keys toggle
directly, so at five groups nobody types at all — and the shape still works at fifty, which is the point
once scenarios can be defined from text. ENTER CLOSES rather than toggling: multi-select needs the thing
that stays open, so toggling is space and the digits, and enter means done.
*/

TAG_PICKER_ROWS :: 9 // as many as the digits reach; a tenth row would need a key nobody would guess

/*
TWO OVERLAYS, ONE PIECE OF SCREEN.

The group picker borrows it, and it is the only thing that does. The keys list used to share this space and
no longer does (it is a `View` now, like `About`) — sharing was the wrong reading of what it is. The picker
belongs to the deals view, describes the list beside it and is meaningless anywhere else; the keys list is
a window-level reference the NOTES view has as much use for. One is a pane, the other is a place. Putting
the second in `.work` meant CTRL+/ in the notes view opened it where that view shows nothing.

Read off the document, like every other piece of state in this window.
*/
tag_picker_open :: proc(app: ^App) -> bool {
	return !effective_display_is_hidden(app, "#tagpicker")
}

toggle_tag_picker :: proc(app: ^App) {
	if !overlays_have_room(app) {
		set_status(app, "the hand page has the whole width — ctrl+\\ brings the controls back")
		return
	}
	set_tag_picker(app, !tag_picker_open(app))
}

set_tag_picker :: proc(app: ^App, open: bool) {
	// The report pane and the picker are the same piece of screen: hiding one is what gives the other its
	// size, both being `size: *` children of `.work`.
	set_shown(app, "#tagpicker", open)
	set_shown(app, "#report", !open)
	if !open {
		// Back to the list, which is where the next thing anybody does lives.
		if list := find(app, "#scenarios"); list != nil {
			_ = sa.set_focus(list)
		}
		return
	}
	draw_tag_picker(app)
	// The picker takes the focus itself, so the digits and space reach the window handler rather than
	// whatever field the caret happened to be in when the key was pressed.
	if picker := find(app, "#tagpicker"); picker != nil {
		_ = sa.set_focus(picker)
	}
	set_status(app, "groups: a number or space toggles, enter closes, backspace clears")
}

// CTRL+/ — the list of every key, from ANY view. `About`'s shape: remember where you were, show it, go
// back. It does NOT consult `overlays_have_room` — that rule is about the deals view's `.work`, and this
// is no longer in it.
toggle_keys_panel :: proc(app: ^App) {
	if current_view(app) == .Keys {
		show_view(app, app.before_keys)
		return
	}
	app.before_keys = current_view(app)
	show_view(app, .Keys)
	if panel := find(app, "#keyspanel"); panel != nil {
		_ = sa.set_focus(panel)
	}
	set_status(app, "keys: esc or ctrl+/ goes back")
}

// The rows. Drawn from `bidding.tags` every time rather than kept, so the tick and the count cannot lag the
// model — the same rule the scenario list follows.
draw_tag_picker :: proc(app: ^App) {
	list := find(app, "#tagpicker-list")
	if list == nil {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	for tag, i in app.groups {
		if i >= TAG_PICKER_ROWS {
			break
		}
		on := i < len(app.tag_on) && app.tag_on[i]
		fmt.sbprintf(
			&b,
			`<div class="tagrow %s" data-tag="%d"><span class="key">%d</span><span class="tick">%s</span><span class="name">%s</span><span class="what">%s</span><span class="count">%d</span></div>`,
			"on" if on else "",
			i,
			i + 1,
			"✓" if on else "·",
			escape_html(tag.name, context.temp_allocator),
			escape_html(tag.description, context.temp_allocator),
			tag_population(app, tag.name),
		)
	}
	sa.set_html(list, strings.to_string(b))
}

/*
The picker's keys, reported like the filter's and taken on the SINKING phase for the same reason.

The digits are the whole point of the shape: five groups means five keys and no typing. There is no cursor
here deliberately — a cursor plus digits is two ways to do one thing — so SPACE toggles nothing on its own
and exists only as the row-past-the-ninth hatch if the vocabulary ever grows past what the digits reach.
*/
tag_picker_key :: proc(app: ^App, key_code: u32, modifiers: sciter.Keyboard_States) -> bool {
	if current_view(app) != .Panes {
		return false
	}
	if sciter.KEYBOARD_STATE_CONTROL & modifiers != {} {
		// CTRL+G, the way in and the way out. `G` for groups, and it is unclaimed anywhere in this window.
		if sciter.Sc_Kb_Codes(key_code) == .G {
			toggle_tag_picker(app)
			return true
		}
		return false
	}
	if !tag_picker_open(app) {
		return false
	}
	// A FIELD WITH THE CARET KEEPS ITS KEYS. The picker stays open while you type in the filter beside it
	// (the two compose, so that is a normal state), and it was taking the field's keys on the way down:
	// backspace cleared every group instead of a character, and the `1` of `1c` toggled the first group.
	// Reported as "deleting does not work in the filter". The picker is driven from the list or the bar,
	// so giving way to a focused text field costs it nothing; ctrl+g still closes it from anywhere.
	if focus_is_text_entry(app) {
		return false
	}
	code := sciter.Sc_Kb_Codes(key_code)
	#partial switch code {
	case .ESCAPE, .ENTER, .KP_ENTER:
		set_tag_picker(app, false)
		return true
	case .BACKSPACE, .DELETE:
		clear_tags(app)
		return true
	}
	// 1-9 on the main row and on the numpad, since a picker driven by digits should not care which ones.
	digit := -1
	if code >= .NUM_1 && code <= .NUM_9 {
		digit = int(code) - int(sciter.Sc_Kb_Codes.NUM_1)
	} else if code >= .KP_1 && code <= .KP_9 {
		digit = int(code) - int(sciter.Sc_Kb_Codes.KP_1)
	}
	if digit >= 0 && digit < len(app.groups) {
		toggle_tag(app, digit)
		return true
	}
	return false
}

// Does the focus sit in something you type into? Asked by the TAG rather than by id, so the deals folder,
// the analyse box and both editors are covered as well as the filter that prompted it.
focus_is_text_entry :: proc(app: ^App) -> bool {
	node, err := sa.focus_element(app.window)
	if err != nil || node == nil {
		return false
	}
	name, terr := sa.tag(node)
	if terr != nil {
		return false
	}
	switch name {
	case "input", "textarea", "plaintext":
		return true
	}
	return false
}

/*
Pick a scenario, from wherever the pick came from — a click, an arrow, or the filter repairing itself.

The three steps were written out at the click site and are now in one place because there are three sites:
the model moves, the list redraws to show it, and the chips, the status line and (if it is open) the pane
follow. `scroll_to_view` is the fourth, and it is what the ARROWS need: the keyboard can move the selection
to a row that is not on screen, which a click by definition cannot.
*/
select_scenario :: proc(app: ^App, index: int) {
	if index < 0 || index >= len(app.scenarios) {
		return
	}
	app.selected = index
	// THE ROWS THEMSELVES DO NOT CHANGE when only the selection moves, so they are not rebuilt. This was
	// `draw_scenarios`, and MEASURED it was the whole cost of holding an arrow key down:
	//
	//     visible_scenarios      0.014 ms      (the ranking - nothing)
	//     draw_scenarios         1.805 ms      (building the html - nothing)
	//     draw_scenarios + pump  95.524 ms     <- the engine, re-styling 110 replaced rows
	//     whole arrow press    112.056 ms
	//
	// `set_html` is a parser AND a re-layout of everything it replaced: a hundred two-line rows thrown away
	// and built again to move one class. Moving the class instead is two element operations, and it is the
	// same lesson the colorizer learned when typing re-marked the whole buffer — pay for what changed.
	mark_selected_row(app)
	if row := find(app, fmt.tprintf(`#scenarios .row[data-index="%d"]`, index)); row != nil {
		_ = sa.scroll_to_view(row)
	}
	note_selected_page(app)
}

// Move the `sel` mark from whatever has it to the selected row. The rows carry their registry index, so
// this finds its target the same way every other path does — and if the selected scenario is not on screen
// (filtered out), nothing is marked, which is the honest answer rather than a mark on a stranger.
mark_selected_row :: proc(app: ^App) {
	if was := find(app, "#scenarios .row.sel"); was != nil {
		_ = sa.set_attribute(was, "class", "row")
	}
	if now := find(app, fmt.tprintf(`#scenarios .row[data-index="%d"]`, app.selected)); now != nil {
		_ = sa.set_attribute(now, "class", "row sel")
	}
}

/*
Move the selection through the VISIBLE rows.

Clamped at both ends rather than wrapped. The palette wraps because twelve rows are a ring you can hold a
key down on; a hundred rows are not, and arriving back at the top after pressing `down` once too often is
the kind of thing that gets noticed only as "it jumped somewhere".
*/
move_scenario_selection :: proc(app: ^App, delta: int) {
	shown := visible_scenarios(app, context.temp_allocator)
	if len(shown) == 0 {
		return
	}
	at := 0
	for index, position in shown {
		if index == app.selected {
			at = position
			break
		}
	}
	select_scenario(app, shown[clamp(at + delta, 0, len(shown) - 1)])
}

/*
The query changed: redraw, and make sure the selection is still something on screen.

THE REPAIR IS NOT TIDINESS. `app.selected` is what generate runs, what the chips describe and what the pane
follows, so a selection filtered off the screen means pressing generate produces a scenario nobody can see
named anywhere in the window. So a filter that hides the selection moves it to the best match — which is
also what typing means: you are aiming at something.

A selection the filter still SHOWS is left exactly where it is, even if it is no longer the best match.
Narrowing a list is not a reason to move off the row you were reading.
*/
filter_scenarios :: proc(app: ^App) {
	shown := visible_scenarios(app, context.temp_allocator)
	// HERE THE ROW SET REALLY HAS CHANGED, so the list is rebuilt — unlike an arrow press, which moves the
	// mark and nothing else (see `select_scenario`). The selection is repaired BEFORE the draw so the
	// redraw marks the right row on its way past, rather than being followed by a second pass to fix it.
	repaired := len(shown) > 0 && !slice.contains(shown, app.selected)
	if repaired {
		app.selected = shown[0]
	}
	draw_scenarios(app)
	if repaired {
		if row := find(app, fmt.tprintf(`#scenarios .row[data-index="%d"]`, app.selected)); row != nil {
			_ = sa.scroll_to_view(row)
		}
		note_selected_page(app) // the chips, the status line and the pane follow the new selection
	}
	// The count, and only while a query is up: the status line's other job is naming the selected
	// scenario's output, which is the more useful thing to be saying once the typing has stopped.
	if app.running || outline.is_blank_query(read_text(app, "#scenario-filter")) {
		return
	}
	set_status(app, fmt.tprintf("%d of %d scenarios", len(shown), len(app.scenarios)))
}

/*
THE WINDOW'S SHORTCUTS: every control in the deals view reachable without the pointer.

WHY ONE PROC AND NOT A KEY BESIDE EACH CONTROL. Every one of these is a key that calls a toggle which
already exists and is already the single place that state is changed — `show_scenario_list`,
`set_pane_mode`, `open_output_format`. Nothing here reimplements a behaviour, so the whole keyboard layer
is a routing table and can be read as one. It sits AFTER the two modal keys (the filter's and the picker's)
because a control that is open owns its keys first: a digit belongs to the picker while the picker is up.

THE SCHEME, and each of the three parts has a precedent rather than a preference behind it:

  * CTRL+1 / CTRL+2 and CTRL+TAB — the tabs. This is exactly the browser's arrangement, down to CTRL+0
    already meaning "reset the zoom" in this window: `0` is the zoom and `1..n` are the tabs, which is
    where several billion hours of muscle memory already point.
  * CTRL+B folds the scenario list. VS Code's sidebar toggle, and the icon in the bar is already the one
    VS Code, JetBrains and GNOME draw for it.
  * CTRL+\ CYCLES the hand page through closed / split / wide, because the segment is ONE control with
    three positions — that was decided when the two toggles were replaced, and a keyboard that offered
    three separate keys would be reintroducing the shape that was wrong. It steps forward and wraps.

FORMATS ARE A CYCLE (CTRL+O), NOT SEVEN DIGITS, and this is the one place the obvious answer is worse.
The chip row shows all seven formats always, but a scenario typically has ONE or TWO on disk: seven keys
would be five dead presses out of seven, and which five changes per scenario. CTRL+O steps to the next
format THAT EXISTS, so the key always does something, and CTRL+SHIFT+O steps back.
*/
window_shortcut_key :: proc(app: ^App, key_code: u32, modifiers: sciter.Keyboard_States) -> bool {
	code := sciter.Sc_Kb_Codes(key_code)

	// BARE ESCAPE CLOSES THE KEYS LIST, and it is the one key here that is not a CTRL one — so it is
	// answered before the gate below. A panel you opened to read is a panel you close without thinking,
	// and escape is what a hand reaches for; requiring CTRL+ESC would be a shortcut for the shortcut list.
	if code == .ESCAPE && current_view(app) == .Keys {
		show_view(app, app.before_keys)
		return true
	}
	// AND THE ABOUT PANEL, for the same reason — it is the other panel you open only to read, and its
	// `close` button was the only way out.
	if code == .ESCAPE && current_view(app) == .About {
		show_about(app, false)
		return true
	}
	if code == .ESCAPE && current_view(app) == .Prefs {
		show_prefs(app, false)
		return true
	}
	// CTRL+W closes whichever of those two is up — the browser's "close this tab", which is what both
	// panels feel like. Only those two: on a working view the key does nothing rather than closing the
	// WINDOW, which would be a costly way to find out what it does.
	if code == .W && sciter.KEYBOARD_STATE_CONTROL & modifiers != {} {
		#partial switch current_view(app) {
		case .About:
			show_about(app, false)
			return true
		case .Keys:
			show_view(app, app.before_keys)
			return true
		case .Prefs:
			show_prefs(app, false)
			return true
		}
	}
	// F6 SWAPS THE KEYBOARD BETWEEN THE LIST AND THE HAND PAGE, and is the other key here that is not a
	// CTRL one. F6 is the Windows convention for "the next pane" and this window now has exactly that
	// question: the list's arrows step scenarios, the page's arrows step BOARDS, and until now the only way
	// to reach the page's was to click it. Bare, because it is a navigation key rather than a command.
	if code == .F6 && current_view(app) == .Panes {
		swap_focus_between_list_and_page(app)
		return true
	}
	if sciter.KEYBOARD_STATE_CONTROL & modifiers == {} {
		return false // everything else here is a CTRL key; a bare one belongs to whatever has the focus
	}
	shift := sciter.KEYBOARD_STATE_SHIFT & modifiers != {}

	// The keys list itself, before the rest: the one shortcut that has to work when you have forgotten
	// every other one.
	if code == .SLASH {
		toggle_keys_panel(app)
		return true
	}

	// The tabs, from anywhere — these are the one group that must work in whichever view you are in.
	#partial switch code {
	case .NUM_1, .KP_1:
		show_view(app, .Panes)
		return true
	case .NUM_2, .KP_2:
		show_editor(app)
		return true
	case .NUM_3, .KP_3:
		show_scenario_editor(app)
		return true
	case .TAB:
		// THREE places now, so "next" is a real direction and SHIFT is the other one — which it was not
		// when there were two and the same key served both. The order is the tab strip's, so the key
		// walks the row somebody can see rather than an enum they cannot.
		#partial switch current_view(app) {
		case .Panes:
			if shift {show_scenario_editor(app)} else {show_editor(app)}
		case .Editor:
			if shift {show_view(app, .Panes)} else {show_scenario_editor(app)}
		case:
			// The scenarios view, and also About and the keys list: those two are errands rather than
			// places, and CTRL+TAB out of one lands where the strip says you are.
			if shift {show_editor(app)} else {show_view(app, .Panes)}
		}
		return true
	}

	// The scenario editor's own keys, before the deals view's: a view that is on screen owns its keys.
	if current_view(app) == .Scenarios {
		#partial switch code {
		case .S:
			_, why := save_scenario_file(app)
			scenario_status(app, why)
			return true
		case .ENTER, .KP_ENTER:
			// The same key the deals view runs with, over the same kind of thing: `check` is this view's
			// "do the thing I am looking at".
			check_scenario(app)
			return true
		case .B:
			set_shown(app, "#scn-files", effective_display_is_hidden(app, "#scn-files"))
			return true
		}
		return false
	}

	// Everything below is about the deals view's furniture and means nothing in the editor.
	if current_view(app) != .Panes {
		return false
	}
	#partial switch code {
	case .B:
		show_scenario_list(app, !scenario_list_shown(app))
		return true
	case .BACKSLASH:
		cycle_pane_mode(app)
		return true
	case .O:
		step_output_format(app, -1 if shift else 1)
		return true
	case .ENTER, .KP_ENTER:
		// CTRL+ENTER RUNS THE THING. It is the "commit this form" key everywhere else — the send in a chat
		// box, the run in a notebook — and it is reachable from inside the fields the run reads, which a
		// plain letter key is not: the count, the seed, the folder and the deal box all take typing, so a
		// key that meant `generate` without a modifier could not be used while filling any of them in.
		//
		// SHIFT picks the other primary action. Generate and analyse are the window's two verbs and they
		// sit in two panels one above the other; one key with one modifier says that better than two
		// unrelated letters would.
		if shift {
			start_analyse(app)
		} else {
			start_generate(app)
		}
		return true
	}
	return false
}

/*
MOVE THE KEYBOARD BETWEEN THE TWO THINGS IN THIS VIEW THAT ANSWER ARROWS.

Reported: "expecting arrows to be able to scroll the html hands page view, need key for swapping between
the scenario list and the hand view page". Both halves answer the arrows and they answer them DIFFERENTLY —
the list steps scenarios, the page steps boards — so which one has the focus is a real question the window
had no way to put. The only way into the page was to click it, and the only way back was to click the list.

Going TO the page forces `focus_page`: its guard is about a page arriving while somebody types, and being
asked to go there is the opposite of that.
*/
swap_focus_between_list_and_page :: proc(app: ^App) {
	if !page_pane_shown(app) {
		set_status(app, "no hand page open — ctrl+\\ opens it beside the list")
		return
	}
	if page_document_has_focus(app) {
		if list := find(app, "#scenarios"); list != nil {
			_ = sa.set_focus(list)
		}
		set_status(app, "the scenario list has the keys — the arrows step scenarios")
		return
	}
	focus_page(app, force = true)
	set_status(app, "the hand page has the keys — the arrows step boards, a/n/e/s/w pick a seat")
}

// Is the focus inside the framed page? Asked of the FRAME element, since the focused element is inside a
// sub-document of its own and is not reachable by walking this document's parents.
page_document_has_focus :: proc(app: ^App) -> bool {
	frame := find(app, "#page")
	if frame == nil {
		return false
	}
	state, err := sa.element_state(frame)
	return err == nil && .FOCUS in state
}

// Closed → split → wide → closed. The segment's own order, so the key and the three buttons step the same
// way round; `set_pane_mode` does the refusing (a pane with nothing in it stays shut and says why).
cycle_pane_mode :: proc(app: ^App) {
	if !page_available(app) {
		set_status(app, "no hand page yet — generate or analyse something, or pick a scenario that has one")
		return
	}
	switch pane_mode(app) {
	case .Closed:
		set_pane_mode(app, .Split)
	case .Split:
		set_pane_mode(app, .Wide)
	case .Wide:
		set_pane_mode(app, .Closed)
	}
}

/*
Open the next format the SELECTED SCENARIO ACTUALLY HAS, `step` places on from the one on screen.

The set it walks is `formats_for`, i.e. what the last `read_dir` found, so the key can never land on a chip
that is drawn dead. Starting point is the format in the pane when that is one of them, so pressing it
repeatedly walks the scenario's outputs in order rather than restarting from the same one.
*/
step_output_format :: proc(app: ^App, step: int) {
	if app.selected < 0 || app.selected >= len(app.scenarios) {
		set_status(app, "pick a scenario in the list first")
		return
	}
	name := app.scenarios[app.selected].name
	have := formats_for(app, name)
	if have == {} {
		set_status(app, fmt.tprintf("nothing generated for %s yet", name))
		return
	}

	// The formats it has, in the enum's own order — the same order the chips are drawn in, so the key walks
	// the row left to right and what happens on screen matches what the hand did.
	present := make([dynamic]Deal_Format, 0, len(Deal_Format), context.temp_allocator)
	for format in Deal_Format {
		if format in have {
			append(&present, format)
		}
	}

	// WHERE THE WALK STARTS: the format on screen, when the pane is showing one of this scenario's files.
	// Otherwise the first press opens the first one rather than the second.
	at := -1
	if app.shown_path != "" {
		if base, format, ok := format_of_extension(filepath.base(app.shown_path)); ok && base == name {
			for candidate, i in present {
				if candidate == format {
					at = i
					break
				}
			}
		}
	}
	next := 0 if at < 0 else ((at + step) %% len(present))
	extensions := FORMAT_EXTENSIONS
	open_output_format(app, extensions[present[next]])
}

// Is the caret in the filter? What decides whether the arrows and escape are the field's (see
// `scenario_filter_key`).
scenario_filter_has_focus :: proc(app: ^App) -> bool {
	input := find(app, "#scenario-filter")
	if input == nil {
		return false
	}
	state, err := sa.element_state(input)
	return err == nil && .FOCUS in state
}

/*
Is the focus IN THE LIST — the list itself, or one of its rows?

Both happen and they are different elements: leaving the filter (enter, escape) focuses `#scenarios`, and
CLICKING a row focuses the ROW, since a row carries `behavior: button` and a button takes the focus when it
is pressed. So this is a walk up from whatever holds the focus rather than a state check on one element.

Bounded at four, like `row_index`'s walk and for the same reason: a row is one level deep, and an unbounded
walk would climb to the document root on every key pressed anywhere else in the window.
*/
scenario_list_has_focus :: proc(app: ^App) -> bool {
	list := find(app, "#scenarios")
	if list == nil {
		return false
	}
	node, err := sa.focus_element(app.window)
	if err != nil || node == nil {
		return false
	}
	for _ in 0 ..< 4 {
		if node == nil {
			break
		}
		if node == list {
			return true
		}
		node = sa.parent(node) or_else nil
	}
	return false
}

// CTRL+R in the deals view. It UNFOLDS THE LIST if it is folded: the field is in the bar and stays on
// screen either way, so without this the key would narrow a list that is not there.
//
// It does not clear what is already typed. A filter is a state you leave on (unlike the palette, which
// opens empty because it closes behind you), and a key that silently discarded it would be the one way to
// lose a query you had just built. Escape is how you clear it, and the hint says so.
focus_scenario_filter :: proc(app: ^App) {
	if !scenario_list_shown(app) {
		show_scenario_list(app, true)
	}
	if input := find(app, "#scenario-filter"); input != nil {
		_ = sa.set_focus(input)
	}
	// AND IT SAYS SO. Reported from the window as "the palette is missing on CTRL+R": the key moved the
	// caret into a small field in the bar and announced itself nowhere, so a person who pressed it saw an
	// accent ring appear somewhere and reasonably concluded the key had done nothing. The picker had a
	// status line from the start and reads as a control being entered; this had none.
	set_status(app, "filter: type to narrow the list, ↑↓ move the selection, esc clears")
}

// Escape: the whole registry back, and the keyboard handed to the list — the same courtesy `close_goto`
// does, for the same reason. Escaping out of a filter means you are done narrowing, not that you want the
// caret left in an empty box.
clear_scenario_filter :: proc(app: ^App) {
	set_input(app, "#scenario-filter", "")
	filter_scenarios(app)
	if list := find(app, "#scenarios"); list != nil {
		_ = sa.set_focus(list)
	}
}

/*
The filter's keys, reported like `goto_key` and `zoom_key` so the caller can leave everything else alone.

INTERCEPTED AT THE SINKING PHASE by the caller, and that is the whole trick — the same one the palette
needs and for the same reason: the query is typed into an `<input>`, whose own edit behavior sees ESCAPE
and the arrows first. Anything that is not one of these four keys falls through and is typed.

CTRL+R is answered wherever the focus is; the rest only while the FIELD HAS THE FOCUS. The arrows belong to
whatever else is on screen in this view, and a `down` pressed with the caret in the deals folder must not
move a selection somebody is not looking at.

The question is asked of the ELEMENT'S STATE rather than of the event's target, and that is not a detail:
a window handler hears the key from wherever the focus is, so the target it arrives with depends on the
routing (synthesised at the document root, it IS the root). Focus is what the rule is actually about.
*/
scenario_filter_key :: proc(app: ^App, key_code: u32, modifiers: sciter.Keyboard_States) -> bool {
	if current_view(app) != .Panes {
		return false
	}
	if sciter.KEYBOARD_STATE_CONTROL & modifiers != {} {
		// The notes view's CTRL+R opens the heading palette, and this is the same question asked of the
		// other half of the window: find a place by name. `goto_key` claims the key only in `.Editor`, so
		// the two never both answer.
		if sciter.Sc_Kb_Codes(key_code) == .R {
			focus_scenario_filter(app)
			return true
		}
		return false
	}
	// THE LIST IS DRIVEN FROM EITHER END OF THE SAME KEYS. The filter is one way IN, not the only place the
	// arrows may be pressed: leaving the field (enter, escape) hands the focus to the list, and CLICKING a
	// row focuses that row — and in both of those the arrows were dead, so the keyboard path dead-ended
	// exactly where somebody had just used it. A list is a control; a focused control answers its arrows.
	in_filter := scenario_filter_has_focus(app)
	if !in_filter && !scenario_list_has_focus(app) {
		return false
	}
	#partial switch sciter.Sc_Kb_Codes(key_code) {
	case .ESCAPE:
		clear_scenario_filter(app)
		return true
	case .DOWN:
		move_scenario_selection(app, 1)
		return true
	case .UP:
		move_scenario_selection(app, -1)
		return true
	case .HOME:
		move_scenario_selection(app, -len(app.scenarios))
		return true
	case .END:
		move_scenario_selection(app, len(app.scenarios))
		return true
	case .PAGE_UP:
		move_scenario_selection(app, -SCENARIO_PAGE_STEP)
		return true
	case .PAGE_DOWN:
		move_scenario_selection(app, SCENARIO_PAGE_STEP)
		return true
	case .ENTER, .KP_ENTER:
		if in_filter {
			// Nothing to CONFIRM — the selection has been following the query all along — so from the field
			// enter means "done typing", and the keyboard goes to the list where the same arrows keep
			// working.
			if list := find(app, "#scenarios"); list != nil {
				_ = sa.set_focus(list)
			}
			return true
		}
		// FROM THE LIST, ENTER SHOWS THE PAGE. This is the one thing arrowing deliberately does NOT do: a
		// closed pane is not followed, because a hand page is up to ~86MB and stepping a hundred rows must
		// not load one each. So the browse is free and the LOOK is a decision, which is what enter is for.
		set_pane_mode(app, .Split if pane_mode(app) == .Closed else pane_mode(app))
		show_selected_page(app, follow = false)
		return true
	}
	return false
}

// How far page-up and page-down move. A screenful of the list is around this at the sizes this window is
// used at, and the exact number matters less than its being a jump rather than a step.
SCENARIO_PAGE_STEP :: 10

draw_scenarios :: proc(app: ^App) {
	list := find(app, "#scenarios")
	if list == nil {
		return
	}
	// THE ROWS ARE WHAT THE FILTER LEAVES, in the order it ranks them - the whole registry in registry order
	// when nothing is typed. Recomputed here rather than remembered: the query lives in the document (the
	// same rule `current_view` and the pane segment follow) and scoring a hundred names costs less than
	// keeping a second copy of the answer in step with it.
	shown := visible_scenarios(app, context.temp_allocator)
	if len(shown) == 0 {
		sa.set_html(list, `<div class="empty">no scenario matches</div>`)
		return
	}
	b := strings.builder_make(context.temp_allocator)
	tags := FORMAT_TAGS
	for i in shown {
		scenario := app.scenarios[i]
		// WHAT HAS BEEN GENERATED FOR THIS ONE, on the row itself. Browsing the list used to be browsing
		// names that might have nothing behind them; the tags turn it into browsing what is THERE. They come
		// out of the single `read_dir` in `scan_outputs`, so a row costs no filesystem call of its own.
		have := formats_for(app, scenario.name)
		marks := strings.builder_make(context.temp_allocator)
		for format in Deal_Format {
			if format in have {
				fmt.sbprintf(&marks, `<span class="tag">%s</span>`, tags[format])
			}
		}
		fmt.sbprintf(
			&b,
			`<div class="row %s" data-index="%d"><span class="name">%s</span><span class="title">%s</span><span class="have">%s</span></div>`,
			"sel" if i == app.selected else "",
			i,
			escape_html(scenario.name, context.temp_allocator),
			escape_html(cli.scenario_title(scenario), context.temp_allocator),
			strings.to_string(marks),
		)
	}
	sa.set_html(list, strings.to_string(b))
}

// WHILE `every scenario` IS ON, EVERY ROW IS MARKED. One class on the list rather than a class per row:
// the rows are replaced wholesale on every redraw, and a per-row mark would have to be re-decided each
// time - this survives a redraw because it is on the element the redraw does not touch.
//
// The selected row keeps its own mark ON TOP of the wash. Both questions are live at once and they are
// different: what the run will cover, and which scenario the chips and the pane are about.
draw_scenario_scope :: proc(app: ^App) {
	list := find(app, "#scenarios")
	if list == nil {
		return
	}
	_ = sa.set_attribute(list, "class", "all" if read_bool(app, "#all") else "")
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
		// The scenario filter's keys, on the way down for exactly the same reason (see `scenario_filter_key`).
		// After the palette's, not before: each claims the key in one view only and the two views are
		// different, so the order is a formality — but the palette is the one with a modal state to get out
		// of, and a key it wants should never have to get past anything.
		if ke.code == .DOWN && ke.phase == .Sinking && scenario_filter_key(app, ke.key_code, ke.modifiers) {
			return true
		}
		// The group picker's keys, sinking as well: while it is open it owns the digits, space, enter and
		// backspace, which every editable thing in this window would otherwise take first.
		if ke.code == .DOWN && ke.phase == .Sinking && tag_picker_key(app, ke.key_code, ke.modifiers) {
			return true
		}
		// The window's own shortcuts, LAST of the sinking group: a control that is open owns its keys
		// first, so a digit is the picker's while the picker is up and a tab switch only after that.
		if ke.code == .DOWN && ke.phase == .Sinking && window_shortcut_key(app, ke.key_code, ke.modifiers) {
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
		// LEAVING THE DEALS FOLDER RE-ASKS WHAT THERE IS TO SHOW. That field says where the pages are READ
		// from as well as written to, so it decides whether the selected scenario has one - which is what
		// the pane segment is alive by and what the status line reports. Nothing else in this document
		// needs an edit event: every other field is read on the click that uses it.
		//
		// On the way OUT, not per keystroke. The edit behavior raises `.VALUE_CHANGED` for every character
		// (the palette's query is built on exactly that), and each answer here asks the filesystem for six
		// candidate paths - a probe per format - which is nothing locally and not nothing on the network
		// share this field points at by default. A half-typed path resolves to nothing anyway, so the
		// answer during typing would be noise as well as work.
		if fe.code == .LOST {
			if id, _ := sa.attribute(fe.target, "id", context.temp_allocator); id == "outdir" {
				scan_outputs(app) // a different folder is a different set of files
				draw_scenarios(app)
				note_selected_page(app)
			}
		}
		return false
	}

	be, ok := sa.behavior_event(event)
	if !ok || be.phase != .Bubbling {
		return false
	}
	// The palette's query, per character: the edit behavior raises `.VALUE_CHANGED` and the list is a
	// projection of what is in the box, so this is the only place the ranking is re-run.
	// A DIVIDER WAS DRAGGED (the script does the drag — see the splitter handlers in `ui/workbench.html`).
	// The deals view's layout is remembered across sessions; the other two views' are not, yet.
	if be.code == .CUSTOM {
		// A CTRL+WHEEL ZOOM, of the window or of the hand page: remember it, as the keyboard's are.
		switch sa.event_name(be, context.temp_allocator) {
		case "wb-zoom":
			factor := zoom_factor(app)
			set_status(app, fmt.tprintf("zoom %d%%", int(factor * 100 + 0.5)))
			remember_zoom(app, factor)
			return true
		case "wb-page-zoom":
			factor := page_zoom_factor(app)
			set_status(app, fmt.tprintf("hand page %d%%", int(factor * 100 + 0.5)))
			remember_page_zoom(app, factor)
			return true
		}
		if sa.event_name(be, context.temp_allocator) == "wb-split-dragged" {
			if id, _ := sa.attribute(be.target, "id", context.temp_allocator); id == "deal-split" {
				take_deal_drag(app)
				remember_deals_layout(app)
			}
			return true
		}
		return false
	}
	if be.code == .VALUE_CHANGED {
		id, _ := sa.attribute(be.target, "id", context.temp_allocator)
		if id == "bml-goto-input" {
			app.goto_sel = 0 // a new query is a new list; keeping the old row would highlight a stranger
			draw_goto_list(app)
			return true
		}
		// THE SCENARIO FILTER IS PER CHARACTER, unlike the deals folder two controls along, which is read
		// only when the focus LEAVES it. The difference is what an answer costs: this one scores a hundred
		// strings in memory, and that one probes a network share for six files per scenario.
		if id == "scenario-filter" {
			filter_scenarios(app)
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
	// A THEME button in the preferences view. By attribute, like the tabs: the three buttons are one
	// control and their word is the pref's value.
	if word, _ := sa.attribute(be.target, "data-theme", context.temp_allocator); word != "" {
		if theme, known := theme_of(word); known {
			choose_theme(app, theme)
			return true
		}
		return false
	}
	if destination, _ := sa.attribute(be.target, "data-view", context.temp_allocator); destination != "" {
		view, known := view_of(destination)
		if !known {
			return false
		}
		switch view {
		case .Editor:
			show_editor(app)
		case .Scenarios:
			// Entered through its own procedure rather than through `show_view`, for the same reason the
			// notes editor is: it has a folder to adopt and a file to open on the first visit.
			show_scenario_editor(app)
		case .Panes:
			show_view(app, view)
		case .About, .Keys, .Prefs:
		// neither is a tab: About is entered from its own button, the keys list from CTRL+/
		}
		return true
	}

	// THE PANE SEGMENT, before the ids and for the same reason the tabs are: the document names the
	// destination (`data-pane`) and this is the only place that spelling is decoded, so a fourth position
	// would be a button plus an enum member and no new case here.
	if wanted, _ := sa.attribute(be.target, "data-pane", context.temp_allocator); wanted != "" {
		mode, known := pane_mode_of(wanted)
		if !known {
			return false
		}
		// The refusal is the MODEL's, not the attribute's: `do_click` runs a disabled button's behavior and
		// delivers the click like any other, so a segment that only LOOKED dead would open an empty pane.
		// `page_available` and not `page_ready`: a page sitting on disk for the selected scenario counts,
		// and opening the pane is what loads it.
		if !page_available(app) {
			set_status(app, "no hand page yet — generate or analyse something, or pick a scenario that has one")
			return true
		}
		set_pane_mode(app, mode)
		return true
	}

	id, _ := sa.attribute(be.target, "id", context.temp_allocator)
	switch id {
	case "generate":
		start_generate(app)
		return true

	case "analyse":
		start_analyse(app)
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

	case "help-generate", "help-analyse", "help-bml", "help-scn":
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

	case "prefs":
		show_prefs(app, true)
		return true

	case "page-zoom-in":
		page_zoom_step(app, 1)
		return true

	case "page-zoom-out":
		page_zoom_step(app, -1)
		return true

	case "page-zoom-reset":
		page_zoom_step(app, 0)
		return true

	case "prefs-close":
		show_prefs(app, false)
		return true

	case "page-browser":
		// WHATEVER IS IN THE PANE, IN A REAL BROWSER. Reported as a gap and it was one: the chips could put
		// a page in the pane and, for the one kind this window cannot host, hand it to a browser - but a
		// cards page you were LOOKING at had no way out at all, and a browser is where a 48-deal page has
		// more room, a find-in-page and a print. It acts on `shown_path` rather than on the selection, so
		// what leaves is what is on screen; a page built in memory by `analyse` has no file and the button
		// is dead for it, which is the honest answer rather than writing a temp file nobody asked for.
		if app.shown_path == "" {
			set_status(app, "nothing in the pane has a file to open — generate or pick one first")
			return true
		}
		// The MODEL refuses too, not just the dimmed button: `do_click` runs a disabled button's behavior
		// and delivers the click like any other.
		if !browsable_page(app.shown_path) {
			set_status(app, "only a page opens in a browser — this is text, and the pane is showing it")
			return true
		}
		open_in_browser(app.shown_path)
		set_status(app, fmt.tprintf("opened %s in your browser", app.shown_path))
		return true

	case "page-dump":
		// Debug builds only — the button is hidden otherwise (see `main`).
		dump_page(app)
		return true

	case "all":
		// The list is the projection of what the run will cover. Read from the CHECKBOX rather than
		// remembered - the same rule the pane segment and `current_view` follow.
		draw_scenario_scope(app)
		return true

	case "deal-list-toggle":
		show_scenario_list(app, !scenario_list_shown(app))
		return true

	case "deal-groups":
		toggle_tag_picker(app)
		return true

	case "scn-files-toggle":
		set_shown(app, "#scn-files", effective_display_is_hidden(app, "#scn-files"))
		return true

	case "scn-folder":
		choose_scenario_folder(app)
		return true

	case "scn-new":
		new_scenario_file(app)
		return true

	case "scn-check":
		check_scenario(app)
		return true

	case "scn-save":
		written, why := save_scenario_file(app)
		scenario_status(app, why)
		if !written {
			log.warnf("the scenario file was not saved: %s", why)
		}
		return true

	case "scn-reload":
		reloaded, why := reload_scenarios(app)
		scenario_status(app, why)
		if !reloaded {
			log.warnf("the scenarios were not reloaded: %s", why)
		}
		return true

	case "scn-words":
		scenario_words(app)
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

	// And a file row in the SCENARIO editor's sidebar. A different attribute (`data-sfile`) rather than a
	// shared one, because these two lists hold different kinds of file and a shared attribute would route
	// a `.scenario` into the BML editor — which would read it, fail to parse it as notes, and say so.
	if name, is_file := row_scenario_file(be.target); is_file {
		switch_scenario_file(app, name)
		return true
	}
	// The `×` on a remembered folder: forget it. BEFORE the row's own attribute, which the walk would find
	// next — a click on the × must not also open the folder it is removing.
	if dir, is_forget := row_attribute(be.target, "data-forget"); is_forget {
		forgot, why := forget_scenario_dir(app, dir)
		scenario_status(app, why)
		if !forgot {
			log.warnf("the scenario folder was not forgotten: %s", why)
		}
		return true
	}
	// A folder in the scenario editor's folders list: edit that folder's files.
	if dir, is_dir := row_attribute(be.target, "data-sdir"); is_dir {
		switch_scenario_dir(app, dir)
		return true
	}

	// Not a button: a scenario row. The click may land on one of the row's own spans, so walk up looking
	// for the `data-index` the render wrote. (The bindings have no `closest`; `parent` is the primitive.)
	// A format chip: open THAT file, rather than the newest one `selected_output` would resolve.
	if extension, _ := sa.attribute(be.target, "data-open", context.temp_allocator); extension != "" {
		open_output_format(app, extension)
		return true
	}

	// A group chip's ×, and a picker row. Both before the scenario rows: a picker row is a `.tagrow` rather
	// than a `.row`, but the chip lives in the bar where a stray `data-index` walk has no business going.
	if raw, _ := sa.attribute(be.target, "data-untag", context.temp_allocator); raw != "" {
		if index, parsed := strconv.parse_int(raw); parsed {
			toggle_tag(app, index)
		}
		return true
	}
	if index, is_tag := row_tag(be.target); is_tag {
		toggle_tag(app, index)
		return true
	}

	if index, is_row := row_index(be.target); is_row {
		select_scenario(app, index)
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

// A clicked row's `attribute`, from the row itself or an ancestor within reach — a row is a span or two
// deep, so the walk is bounded the way `row_file`'s is.
row_attribute :: proc(element: sa.Element, attribute: string) -> (value: string, ok: bool) {
	node := element
	for _ in 0 ..< 3 {
		if node == nil {
			break
		}
		if raw, err := sa.attribute(node, attribute, context.temp_allocator); err == nil && raw != "" {
			return raw, true
		}
		node = sa.parent(node) or_else nil
	}
	return "", false
}

// The `.scenario` file a clicked row names. `row_file`'s twin, and bounded the same way.
row_scenario_file :: proc(element: sa.Element) -> (name: string, ok: bool) {
	node := element
	for _ in 0 ..< 3 {
		if node == nil {
			break
		}
		if raw, err := sa.attribute(node, "data-sfile", context.temp_allocator); err == nil && raw != "" {
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

// The group a clicked picker row names: itself, or the nearest ancestor carrying `data-tag`. Bounded the
// same way `row_index` is — a row is one `<span>` deep and an unbounded walk would reach the document root
// on every click that is not one.
row_tag :: proc(element: sa.Element) -> (index: int, ok: bool) {
	node := element
	for _ in 0 ..< 3 {
		if node == nil {
			break
		}
		if raw, err := sa.attribute(node, "data-tag", context.temp_allocator); err == nil && raw != "" {
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
	app.selected = 0
	// THE PREFS BEFORE THE SCENARIOS. The remembered pref (a file rather than the document's `@storage`:
	// see `prefs/prefs.odin`) holds the scenario folders as well as the layout, and this used to be read a
	// hundred lines further down — so `load_user_scenarios` saw no folders at startup, the deals list had
	// none of the user's scenarios, and only a rescan found them. Reported as "starts off with no folder".
	load_prefs_and_scenarios(app, prefs.default_path(app.allocator))
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

	// AND THE HAND PAGE'S FRAME, for its own follow timer. A SECOND handler struct rather than the same one
	// attached twice: a handler must not move after attaching, and one struct registered against two
	// elements is one address the engine holds twice — the frames are different elements with different
	// timers, so they get one each.
	// BEHAVIOR_EVENT as well, for `.DOCUMENT_COMPLETE`: a page arriving through `loadFile` is not there when
	// the call returns, so its zoom can only be put on it when the frame says the document is done.
	app.page_handler = sa.Event_Handler {
		subscription = {.TIMER, .BEHAVIOR_EVENT},
		on_event     = on_frame_event,
		user_data    = app,
	}
	if frame := sa.select_first(sa.root(window) or_else nil, "#page") or_else nil; frame != nil {
		sa.attach_handler(frame, &app.page_handler)
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

	// The drag log, in debug builds: see `WB_DRAG_LOG` in the document's script.
	when ODIN_DEBUG {
		if result, err := sa.eval(window, "WB_DRAG_LOG = true"); err == nil {
			sa.value_clear(&result)
		}
	}

	// The remembered theme, now that there is a document to put it on (see `theme.odin`).
	apply_theme(app, chosen_theme(app))

	out_dir, out_note := default_out_dir(context.temp_allocator)
	set_input(app, "#outdir", out_dir)

	// The BML editor's corpus, resolved once at startup rather than per visit: it is a property of where
	// this process is running, not of anything the user does in the window. An empty result is not fatal —
	// the generator and the advisor do not need the notes — so the editor button simply reports it.
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
	restore_page_zoom(app)
	restore_deals_layout(app)

	// What is already in the deals folder, BEFORE the list is drawn: the rows carry their format tags from
	// the first frame, so a window opened on a folder from an earlier session says what is in it rather
	// than looking empty until something is pressed.
	scan_outputs(app)
	draw_scenarios(app)
	draw_scenario_scope(app)
	note_selected_page(app)
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
	delete(app.shown_path, app.allocator)
	for name in app.scn_names {
		delete(name, app.allocator)
	}
	delete(app.scn_names, app.allocator)
	delete(app.scn_open, app.allocator)
	delete(app.scn_dir, app.allocator)
	delete(app.tag_on, app.allocator)
	delete(app.groups, app.allocator)
	// The loaded scenarios own the PROGRAMS the interpreted conditions point into, so this frees the
	// trees as well as the list. `app.scenarios` is the concatenation and owns nothing itself — and the
	// order is the registry first, since its conditions point into what the next line frees.
	free_user_scenarios(app)
	clear_outputs(app)
	delete(app.outputs)
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
		// The same resolution the selection uses, so the measured page is one the application would show.
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
/*
THE STYLESHEET IS CUT INTO `<style>` BLOCKS THAT FIT, AUTOMATICALLY. Nobody has to think about this again.

AN INLINE `<style>` IS CAPPED AT 32 KiB IN THIS ENGINE, ALL OR NOTHING: at one byte over, the WHOLE block is
discarded - its first rule included - with no warning, and the engine`s CSS diagnostics go quiet for that
sheet at the same moment. The card page hit this first (`norn`; `page-check` asserts its byte count), and
this file hit it the moment the deals view grew its format chips, at 35,781 bytes.

WHAT IT LOOKS LIKE WHEN IT HAPPENS is the reason this is worth automating rather than watching: nothing
says "stylesheet". Every `behavior: button` in the document stops attaching, so scenario rows, file rows and
palette entries answer `do_click` with `handled = false`, and three unrelated tests fail as though the event
routing had broken. It cost most of an afternoon the first time and it would cost it again.

THE SCOPE OF THE CAP IS ONE `<style>` ELEMENT - two blocks of 20 KB both apply, measured - so the fix is to
emit several. The first version of this had a marker comment in the stylesheet and a test telling whoever
tripped it to MOVE THE MARKER, which is the same cliff one step further back: it still fails, still fails
loudly-but-late, and still needs a person to understand the trap. So the sheet is now cut HERE, at parse
time, into as many blocks as it takes.

The cut points are TOP-LEVEL RULE BOUNDARIES and nothing else, which is what makes this safe:

  * BLOCK COMMENTS are skipped whole, because this file`s own comments contain braces (they quote
    `@set name { … }` and `@media` blocks) and a naive brace count would cut inside a sentence;
  * depth is tracked, so an `@media` or `@set` block is never cut in half;
  * the order of the rules is preserved exactly, so the cascade is what the file says it is.

A block that would exceed `CSS_BUDGET` starts a new one. The budget is well under the cap because the cost
of another `<style>` element is nothing and the cost of being wrong is the whole sheet. ONE RULE BIGGER THAN
THE BUDGET still goes out whole - splitting it would be worse than shipping it - and the test says so.
*/
CSS_CAP :: 32 * 1024 // the engine`s hard limit for ONE inline <style> (measured: 32,741 applies, 32,769 does not)
CSS_BUDGET :: 24 * 1024 // what this aims at, leaving room for a big rule to land on top of a full block

// What one `<style>` becomes two with. Named because the tests assert on it.
CSS_JOIN :: "</style>\n<style>\n"

/*
Cut a stylesheet into blocks that each fit, at top-level rule boundaries.

Returns slices INTO the input - no copying - so the caller can concatenate them with the join. A sheet that
already fits comes back as one block, which is the common case and costs one pass.
*/
css_blocks :: proc(css: string, budget := CSS_BUDGET, allocator := context.allocator) -> []string {
	blocks := make([dynamic]string, 0, 4, allocator)
	depth := 0
	block_start := 0
	rule_start := 0
	i := 0
	for i < len(css) {
		// A comment is skipped WHOLE: the braces inside this file`s prose are not structure.
		if i + 1 < len(css) && css[i] == '/' && css[i + 1] == '*' {
			closing := strings.index(css[i + 2:], "*/")
			if closing < 0 {
				break // unterminated: the rest is comment, and there is nothing left to cut
			}
			i += 2 + closing + 2
			continue
		}
		switch css[i] {
		case '{':
			depth += 1
		case '}':
			depth -= 1
			if depth <= 0 {
				depth = 0
				// End of a top-level rule. Take everything up to here as one candidate, and close the
				// current block BEFORE it if adding it would go over.
				rule_end := i + 1
				if rule_end - block_start > budget && rule_start > block_start {
					append(&blocks, css[block_start:rule_start])
					block_start = rule_start
				}
				rule_start = rule_end
			}
		}
		i += 1
	}
	if block_start < len(css) {
		append(&blocks, css[block_start:])
	}
	return blocks[:]
}

compose_document :: proc(allocator := context.allocator) -> string {
	html := string(UI_HTML)
	marker := strings.index(html, CSS_MARKER)
	if marker < 0 {
		return html // no marker: the document is still valid, just unstyled
	}
	blocks := css_blocks(string(UI_CSS), CSS_BUDGET, context.temp_allocator)
	// The marker sits inside a `<style>` in the document, so every block after the first closes that
	// element and opens one of its own.
	styled := strings.join(blocks, CSS_JOIN, context.temp_allocator)
	return strings.concatenate({html[:marker], styled, html[marker + len(CSS_MARKER):]}, allocator)
}

// `transcribe` without the cross-thread message: for the engine thread, before any worker exists.
transcribe_local :: proc(app: ^App, line: string) {
	strings.write_string(&app.transcript, line)
	strings.write_byte(&app.transcript, '\n')
	draw_transcript(app)
}
