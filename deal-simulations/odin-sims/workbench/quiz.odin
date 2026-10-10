package main

/*
	quiz.odin — a bidding quiz for the open `.bml` file, as one HTML page to open in a browser or share.

	THE PAGE IS A TEMPLATE WITH A SLOT. The quiz itself — the engine, the filter, Datastar, the routes — is
	compiled to WebAssembly in the bridge-system-apps repo (`apps/datastar-quiz-wasm`) and written out as one
	self-contained HTML file whose corpus is EMPTY: the text `/*QUIZ_CORPUS*/`, once. Generating a quiz is
	reading the bid tables out of the editor's buffer (`quiz_corpus`, held auction for auction to the python
	quiz over every file in the corpus), writing them as JSON into that slot, and saving the result.

	THE QUIZ STRIP is a line under the notes bar (not in it: the bar is one line by rule and was full):
	`generate quiz`, `open quiz in browser` when a page exists, and a sentence saying whether this file has a
	quiz page, how old it is, and whether the notes were saved after it.

	THE TEMPLATE IS BUILT IN. `ui/quiz-template.html` is a VENDORED copy, `#load`ed into the exe, so the
	button works for anyone running the workbench - nothing to install, find or configure. It is refreshed
	from the apps repo by `just dswasm vendor-template` there (the apps repo writes into this one, which is
	the direction the two already depend in; nothing here builds against that repo). A path in the settings
	OVERRIDES it, for trying a newly built template without rebuilding the workbench; an override that
	cannot be used falls back to the built-in copy and says so, rather than leaving the button dead.

	Every message here is for the person USING the window: no build commands, no repo names.

	FROM THE BUFFER, NOT THE FILE. Like the preview, the quiz is of what is in the editor, unsaved edits
	included — `#INCLUDE`s are resolved from disk as the preview resolves them.

	THE PAGE IS NOT SHOWN HERE. The quiz runs WebAssembly, which this engine's script does not; it is a page
	for a browser, so the view offers `open quiz in browser` rather than loading it into a pane.

	THE VIEW KNOWS WHETHER A QUIZ EXISTS. Whenever a file is opened (and after a save, a generate, or a change
	to where quizzes go) `refresh_quiz` looks for that file's page on disk: the open button is there exactly
	when the page is, and says how old it is and whether the notes have been SAVED since it was written - a
	quiz older than its notes is still worth opening, but it is missing the latest changes. Looking costs one
	stat; it never creates the folder (`quiz_file_for` does not, unlike the generate path).

	TOPICS are the file's own `#+TOPIC: Name = pattern, pattern` lines, then the generic defaults
	(`quiz_corpus/topics.odin`); the quiz page keeps only those that select enough auctions to quiz on. A
	topic line that cannot be read is reported in the status line rather than dropped in silence.

	THE NOTES GO WITH THE QUIZ. Its "System Notes" panel shows the file itself, rendered exactly as the
	preview renders it and carried inside the page, because a quiz made from any `.bml` file has no
	published page to point at - and an offline page should not depend on one.
*/

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../prefs"
import "../quiz_corpus"
import bml "markup:."
import sa "sciter:sciter_app"

// The quiz page with an empty corpus slot, compiled in. See the header.
QUIZ_TEMPLATE_BUILTIN :: #load("../ui/quiz-template.html", string)

// An override for the built-in template, and where quizzes are written. Both are settings (see
// `draw_quiz_prefs`).
QUIZ_TEMPLATE_PREF :: "quiz.template"
QUIZ_DIR_PREF :: "quiz.dir"

// The template's one contract: this text, exactly once, is where the corpus JSON goes.
QUIZ_CORPUS_SLOT :: "/*QUIZ_CORPUS*/"

// A question offers up to eight candidates, each with its own meaning, so a file with fewer distinct
// meanings than that cannot fill a question at the top difficulty — the page would show a broken card.
QUIZ_MIN_MEANINGS :: 8

// The override's path: the setting, else `QUIZ_TEMPLATE` from the environment, else "" for none.
quiz_template_override :: proc(app: ^App) -> string {
	if path, found := prefs.get(&app.prefs, QUIZ_TEMPLATE_PREF); found && strings.trim_space(path) != "" {
		return strings.trim_space(path)
	}
	return os.get_env("QUIZ_TEMPLATE", context.temp_allocator)
}

/*
The template to fill: the override when there is one and it is usable, else the built-in copy.

`note` is "" in the ordinary case and otherwise a sentence for the status line - which override was used,
or why it was not.
*/
quiz_template :: proc(app: ^App) -> (template: string, note: string) {
	override := quiz_template_override(app)
	if override == "" {
		return QUIZ_TEMPLATE_BUILTIN, ""
	}
	data, err := os.read_entire_file_from_path(override, context.temp_allocator)
	if err != nil {
		return QUIZ_TEMPLATE_BUILTIN, fmt.tprintf(
			"the quiz template in Settings could not be read (%s), so the built-in one was used",
			override,
		)
	}
	if strings.count(string(data), QUIZ_CORPUS_SLOT) != 1 {
		return QUIZ_TEMPLATE_BUILTIN, fmt.tprintf("%s is not a quiz template, so the built-in one was used", override)
	}
	return string(data), fmt.tprintf("using the quiz template from Settings (%s)", override)
}

// The folder setting as typed: the quiz setting, else the deals folder.
@(private = "file")
quiz_dir_typed :: proc(app: ^App) -> string {
	if chosen, found := prefs.get(&app.prefs, QUIZ_DIR_PREF); found && strings.trim_space(chosen) != "" {
		return strings.trim_space(chosen)
	}
	return strings.trim_space(read_text(app, "#outdir"))
}

// Where the open file's quiz page is, or would be - WITHOUT creating anything. "" when there is no file
// open or the folder setting is not a usable path.
quiz_file_for :: proc(app: ^App) -> string {
	typed := quiz_dir_typed(app)
	if app.bml_open == "" || typed == "" {
		return ""
	}
	dir, err := filepath.abs(typed, context.temp_allocator)
	if err != nil {
		return ""
	}
	stem := strings.trim_suffix(app.bml_open, ".bml")
	path, jerr := filepath.join({dir, fmt.tprintf("%s-quiz.html", stem)}, context.temp_allocator)
	return path if jerr == nil else ""
}

// Where a quiz is written: the setting, else the deals folder (created if missing, as a generate run does).
quiz_out_dir :: proc(app: ^App) -> (dir: string, err: string) {
	return resolve_out_dir(quiz_dir_typed(app))
}

/*
The template with the corpus in its slot. Pure, so it is tested without a window.

`</` is written `<\/` inside the JSON — the same string to a JSON parser, but it can never close the
`<script>` element the corpus sits in, whatever a description says.
*/
fill_quiz_template :: proc(
	template, corpus_json: string,
	allocator := context.allocator,
) -> (
	page: string,
	why: string,
) {
	at := strings.index(template, QUIZ_CORPUS_SLOT)
	if at < 0 {
		return "", "the quiz template is damaged (it has nowhere to put the questions)"
	}
	if strings.index(template[at + len(QUIZ_CORPUS_SLOT):], QUIZ_CORPUS_SLOT) >= 0 {
		return "", "the quiz template is damaged (it has two places to put the questions)"
	}
	safe, _ := strings.replace_all(corpus_json, "</", `<\/`, context.temp_allocator)
	return strings.concatenate({template[:at], safe, template[at + len(QUIZ_CORPUS_SLOT):]}, allocator), ""
}

/*
The notes as a page of their own, for the quiz's "System Notes" panel: the library's html with the notes
stylesheet INLINED, because the quiz is one file and a relative `bml.css` would resolve to nothing. The same
treatment the preview gives them (`preview_document`), minus what is particular to this engine - the quiz
is shown in a browser. The webfont link goes too: the page has to read offline, and falls back to the
stylesheet's other fonts.
*/
quiz_notes_document :: proc(app: ^App, html: string, allocator := context.allocator) -> string {
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
	if head < 0 || css == "" {
		return strings.clone(stripped, allocator)
	}
	cut := head + len("<head>")
	return strings.concatenate({stripped[:cut], "<style>", css, "</style>", stripped[cut:]}, allocator)
}

// How many different meanings a corpus has to ask about (a row with no description cannot be asked).
distinct_meanings :: proc(auctions: []quiz_corpus.Auction) -> int {
	seen := make(map[string]struct{}, allocator = context.temp_allocator)
	for auction in auctions {
		if strings.trim_space(auction.description) != "" {
			seen[auction.description] = {}
		}
	}
	return len(seen)
}

// The page for one document: its auctions, topics and notes in the template. `bml_file` names the system.
quiz_page :: proc(
	doc: ^bml.Document,
	bml_file: string,
	template: string,
	topics: []quiz_corpus.Topic = nil,
	notes_html := "",
	allocator := context.allocator,
) -> (
	page: string,
	auctions: int,
	why: string,
) {
	notes_url := fmt.tprintf(quiz_corpus.EMBEDDED_NOTES_URL, 0) if notes_html != "" else ""
	system := quiz_corpus.system_for_document(
		doc,
		bml_file,
		notes_url,
		topics,
		notes_html,
		allocator = context.temp_allocator,
	)
	auctions = len(system.auctions)
	if auctions == 0 {
		return "", 0, fmt.tprintf("%s has no bid tables - nothing to quiz", bml_file)
	}
	if meanings := distinct_meanings(system.auctions); meanings < QUIZ_MIN_MEANINGS {
		return "", auctions, fmt.tprintf(
			"%s has %d different meanings in its bid tables - a quiz needs at least %d",
			bml_file,
			meanings,
			QUIZ_MIN_MEANINGS,
		)
	}
	corpus, ok := quiz_corpus.corpus_json([]quiz_corpus.Exported_System{system}, context.temp_allocator)
	if !ok {
		return "", auctions, "the quiz's questions could not be written out"
	}
	page, why = fill_quiz_template(template, corpus, allocator)
	return page, auctions, why
}

// The `quiz` button: write the open file's quiz page, and offer it to the browser.
generate_quiz :: proc(app: ^App) -> (ok: bool, why: string) {
	if app.bml_open == "" {
		return false, "nothing is open"
	}
	template, template_note := quiz_template(app)
	source, got := bml_source(app, context.temp_allocator)
	if !got {
		return false, "the editor's text could not be read"
	}
	doc := bml.parse(source, {resolve_include = bml_include, include_user = app})
	defer bml.destroy(doc)

	topics, topic_problems := quiz_corpus.read_topics(source, bml_include, app, context.temp_allocator)
	notes := quiz_notes_document(app, bml.render_html(doc, context.temp_allocator), context.temp_allocator)
	page, auctions, page_why := quiz_page(
		doc,
		app.bml_open,
		template,
		quiz_corpus.topics_for_quiz(topics, context.temp_allocator),
		notes,
		context.temp_allocator,
	)
	if page_why != "" {
		return false, page_why
	}

	dir, dir_err := quiz_out_dir(app)
	if dir_err != "" {
		return false, dir_err
	}
	stem := strings.trim_suffix(app.bml_open, ".bml")
	path, jerr := filepath.join({dir, fmt.tprintf("%s-quiz.html", stem)}, context.temp_allocator)
	if jerr != nil {
		return false, "could not make the quiz's path"
	}
	if werr := os.write_entire_file(path, transmute([]u8)page); werr != nil {
		return false, fmt.tprintf("could not write %s: %v", path, werr)
	}

	refresh_quiz(app)
	done := fmt.tprintf(
		"quiz of %s · %d auctions · %d topic%s of its own · written to %s",
		app.bml_open,
		auctions,
		len(topics),
		"" if len(topics) == 1 else "s",
		path,
	)
	if len(topic_problems) > 0 {
		first := topic_problems[0]
		in_file := first.file if first.file != "" else app.bml_open
		done = fmt.tprintf(
			"%s · %d topic line%s not understood - %s line %d: %s",
			done,
			len(topic_problems),
			"" if len(topic_problems) == 1 else "s",
			in_file,
			first.line,
			first.why,
		)
	}
	if template_note != "" {
		done = fmt.tprintf("%s · %s", done, template_note)
	}
	return true, done
}

/*
Is there a quiz page for the open file? Show the open button if so - with its age, and whether the notes
were saved after it was written - and hide it if not.

Called on opening a file, after a save, after generating, and when either folder setting changes.
*/
refresh_quiz :: proc(app: ^App) {
	delete(app.quiz_path, app.allocator)
	app.quiz_path = ""
	set_shown(app, "#bml-quizbar", app.bml_open != "")
	path := quiz_file_for(app)
	quiz: os.File_Info
	qerr: os.Error = os.General_Error.Not_Exist
	if path != "" {
		quiz, qerr = os.stat(path, context.temp_allocator)
	}
	if qerr != nil || quiz.type == .Directory {
		set_shown(app, "#bml-quiz-open", false)
		set_quiz_state(app, "no quiz page for this file yet", false)
		return
	}
	app.quiz_path = strings.clone(path, app.allocator)

	// STALE: the .bml on disk was saved after the quiz was written. The buffer is not compared - a quiz
	// generated from unsaved text is newer than the file, and rightly reads as current.
	stale := false
	if notes, jerr := filepath.join({app.docs, app.bml_open}, context.temp_allocator); jerr == nil {
		if info, serr := os.stat(notes, context.temp_allocator); serr == nil {
			stale = time.diff(quiz.modification_time, info.modification_time) > 0
		}
	}
	age := age_words(time.since(quiz.modification_time))
	hint := fmt.tprintf(
		"Open this file's quiz page in your web browser - %s, written %s.%s The page is one self-contained file: copy it anywhere, it needs no server.",
		filepath.base(path),
		age,
		" The notes have been changed since, so it is missing those changes: generate the quiz again to update it." if stale else "",
	)
	if button := find(app, "#bml-quiz-open"); button != nil {
		sa.set_attribute(button, "data-hint", hint)
		sa.set_attribute(button, "title", fmt.tprintf("Open the quiz page in your web browser (written %s)", age))
	}
	set_quiz_state(
		app,
		fmt.tprintf(
			"%s · written %s%s",
			filepath.base(path),
			age,
			" · out of date: the notes have changed since - generate again to include them" if stale else "",
		),
		stale,
	)
	set_shown(app, "#bml-quiz-open", true)
}

@(private = "file")
set_quiz_state :: proc(app: ^App, text: string, stale: bool) {
	set_text_at(app, "#bml-quiz-state", text)
	if state := find(app, "#bml-quiz-state"); state != nil {
		sa.set_attribute(state, "class", "barlabel quizstate stale" if stale else "barlabel quizstate")
	}
}

// "just now", "5 minutes ago", "3 hours ago", "2 days ago".
age_words :: proc(age: time.Duration) -> string {
	minutes := int(time.duration_minutes(age))
	switch {
	case minutes < 1:
		return "just now"
	case minutes < 60:
		return fmt.tprintf("%d minute%s ago", minutes, "" if minutes == 1 else "s")
	case minutes < 48 * 60:
		hours := minutes / 60
		return fmt.tprintf("%d hour%s ago", hours, "" if hours == 1 else "s")
	}
	return fmt.tprintf("%d days ago", minutes / (24 * 60))
}

// ---------------------------------------------------------------------------------------------------
// The settings

// Fill the two fields from what is remembered.
draw_quiz_prefs :: proc(app: ^App) {
	template, _ := prefs.get(&app.prefs, QUIZ_TEMPLATE_PREF)
	set_input(app, "#prefs-quiz-template", template)
	dir, _ := prefs.get(&app.prefs, QUIZ_DIR_PREF)
	set_input(app, "#prefs-quiz-dir", dir)
	_, note := quiz_template(app)
	set_text_at(app, "#prefs-quiz-note", note if note != "" else "the quiz uses its built-in template")
}

// A settings field was left: remember what it holds. Returns whether `id` was one of the quiz's fields.
remember_quiz_pref :: proc(app: ^App, id: string) -> bool {
	key: string
	switch id {
	case "prefs-quiz-template":
		key = QUIZ_TEMPLATE_PREF
	case "prefs-quiz-dir":
		key = QUIZ_DIR_PREF
	case:
		return false
	}
	value := strings.trim_space(read_text(app, fmt.tprintf("#%s", id)))
	// Explorer's "copy as path" wraps the path in quotes.
	value = strings.trim(value, `"`)
	// A test's App has no store and no path, and setting a key on a nil map is a crash, not a no-op.
	if app.prefs.values != nil {
		prefs.set(&app.prefs, key, value)
		if app.prefs_path != "" {
			_ = prefs.save(&app.prefs, app.prefs_path)
		}
	}
	draw_quiz_prefs(app)
	refresh_quiz(app) // a different folder may hold a different page, or none
	return true
}
