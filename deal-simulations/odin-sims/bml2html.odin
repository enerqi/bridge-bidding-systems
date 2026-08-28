package main

/*
	bml2html — convert this repository's `.bml` notes to `.html`, in ONE process.

	  just bml2html                       # every *.bml in the working directory
	  just bml2html nt-bidding.bml        # a subset
	  just bml2html --stdout nt-bidding.bml   # one file to stdout (the parity oracle's shape)

	A `-file` program like `sim.odin`, `analyse_deal.odin` and `page_check.odin`, and the thinnest of the
	four: the whole conversion is `bml.parse` + `bml.render_html` from the `bridge-markup` library
	(`markup:.`), reached here through the `markup` collection. Nothing bridge-specific lives in this file.

	WHY IT EXISTS. The build was one `bml2html.py` SUBPROCESS PER FILE, and it had to be: the python `bml`
	module keeps its parse state in module globals, so one process cannot convert two documents. The Odin
	library owns its state per parse, so 19 files are 19 tasks on one thread pool in one process — and each
	parse is ~2 ms rather than ~30 ms plus interpreter startup.

	BYTE PARITY IS THE POINT, and two details of it are easy to lose:

	  - The reference writes with python's TEXT mode, so on Windows every `\n` became `\r\n` on disk. The
	    published pages on `w:/` were produced that way, so file output here translates too
	    (`--lf` opts out). `--stdout` never translates: that is the byte stream 'just parity' compares.
	  - The reference writes `basename(arg).split(".")[0] + ".html"` into the WORKING DIRECTORY, not beside
	    the input. `--out-dir` defaults to the same thing, so `just bml` from the repository root is
	    unchanged.

	`#INCLUDE` is resolved relative to the working directory (as the reference does, which is why the quiz
	has to chdir around a parse) and then relative to the source file's own directory, so naming a file in
	another directory works instead of silently rendering an empty body.
*/

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import si "core:sys/info"
import "core:thread"
import "core:time"

import bml "markup:."

// One file's conversion. Filled in on a worker thread, reported on the main one so the output stays in
// argument order rather than in completion order.
Job :: struct {
	path:        string, // as given on the command line
	source_dir:  string, // for the second `#INCLUDE` lookup
	out_path:    string, // "" for --stdout
	check_links: bool,
	html:        string,
	// Already formatted by `bml.diagnostic_text`, so each one carries `file:line:col:` in front of
	// the sentence - the shape an editor's error list and a compiler both use.
	diagnostics: []string,
	failure:     string, // "" on success
}

Options :: struct {
	out_dir:     string,
	to_stdout:   bool,
	lf:          bool,
	check_links: bool,
	jobs:        int,
}

main :: proc() {
	opts, files, args_ok := parse_args(os.args[1:])
	if !args_ok {
		os.exit(2)
	}

	if len(files) == 0 {
		matches, glob_err := filepath.glob("*.bml")
		if glob_err != nil {
			fmt.eprintfln("bml2html: could not list *.bml: %v", glob_err)
			os.exit(1)
		}
		files = matches
	}
	if len(files) == 0 {
		fmt.eprintln("bml2html: no .bml files")
		os.exit(1)
	}
	if opts.to_stdout && len(files) != 1 {
		fmt.eprintfln("bml2html: --stdout renders one file, %d given", len(files))
		os.exit(2)
	}

	jobs := make([]Job, len(files))
	for file, i in files {
		jobs[i] = Job {
			path        = file,
			source_dir  = filepath.dir(file),
			out_path    = opts.to_stdout ? "" : output_path(file, opts.out_dir),
			check_links = opts.check_links,
		}
	}

	started := time.now()
	// One task per file. `pool_finish` also works tasks on this thread, so a single-file run never pays
	// for a handoff.
	pool: thread.Pool
	thread.pool_init(&pool, context.allocator, min(opts.jobs, len(jobs)))
	defer thread.pool_destroy(&pool)
	for &job, i in jobs {
		thread.pool_add_task(&pool, context.allocator, convert_worker, &job, i)
	}
	thread.pool_start(&pool)
	thread.pool_finish(&pool)

	failed: int
	for &job in jobs {
		for diagnostic in job.diagnostics {
			fmt.eprintfln("%s: %s", job.path, diagnostic)
		}
		if job.failure != "" {
			fmt.eprintfln("bml2html: %s: %s", job.path, job.failure)
			failed += 1
			continue
		}
		if opts.to_stdout {
			fmt.print(job.html)
			continue
		}
		if write_msg, write_ok := write_html(job.out_path, job.html, opts.lf); !write_ok {
			fmt.eprintfln("bml2html: %s: %s", job.path, write_msg)
			failed += 1
		}
	}

	if failed > 0 {
		os.exit(1)
	}
	if !opts.to_stdout {
		fmt.printf("built %d html in %.2fs\n", len(jobs), time.duration_seconds(time.since(started)))
	}
}

// The library call, off the main thread. Everything it produces is heap-allocated and outlives the
// document, because `bml.destroy` is a wholesale arena free: the html is a fresh string, and the
// diagnostics have to be COPIED before the arena goes.
convert_worker :: proc(t: thread.Task) {
	job := cast(^Job)t.data
	source, read_err := os.read_entire_file(job.path, context.allocator)
	if read_err != nil {
		job.failure = fmt.aprintf("could not read it: %v", read_err)
		return
	}
	defer delete(source)

	doc := bml.parse(
		string(source),
		{resolve_include = resolve_include, include_user = job, check_cross_references = job.check_links},
	)
	defer bml.destroy(doc)

	job.html = bml.render_html(doc)
	if len(doc.diagnostics) > 0 {
		copies := make([]string, len(doc.diagnostics))
		for diagnostic, i in doc.diagnostics {
			copies[i] = bml.diagnostic_text(diagnostic)
		}
		job.diagnostics = copies
	}
}

// `#INCLUDE name`: the working directory first (the reference's behaviour, and what `just bml` relies on),
// then the including file's own directory. A miss is a diagnostic inside the library, not an error here —
// a half-typed document in the preview must still render.
resolve_include :: proc(name: string, user: rawptr, allocator: mem.Allocator) -> (text: string, ok: bool) {
	if data, err := os.read_entire_file(name, allocator); err == nil {
		return string(data), true
	}
	job := cast(^Job)user
	if job == nil || job.source_dir == "" || job.source_dir == "." {
		return "", false
	}
	beside, _ := filepath.join({job.source_dir, name}, context.temp_allocator)
	data, err := os.read_entire_file(beside, allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// `<out_dir>/<stem>.html`, where the stem is the reference's `basename(path).split(".")[0]` — the FIRST
// dot, not the last, so a `2c.opener.bml` would become `2c.html` in both implementations.
output_path :: proc(path: string, out_dir: string) -> string {
	name := filepath.base(path)
	if dot := strings.index_byte(name, '.'); dot >= 0 {
		name = name[:dot]
	}
	file := strings.concatenate({name, ".html"})
	if out_dir == "" {
		return file
	}
	defer delete(file)
	joined, _ := filepath.join({out_dir, file})
	return joined
}

// CRLF on Windows unless `--lf`, because that is what python's text mode wrote and what the published
// pages are. `publish` compares CONTENT, so getting this wrong would rewrite every file on the web volume
// once and then look identical forever - silent, but a needless network copy of the whole corpus.
write_html :: proc(path: string, html: string, lf: bool) -> (msg: string, ok: bool) {
	bytes := html
	translate := !lf && ODIN_OS == .Windows
	if translate {
		bytes, _ = strings.replace_all(html, "\n", "\r\n")
	}
	defer if translate {
		delete(bytes)
	}
	if write_err := os.write_entire_file(path, transmute([]u8)bytes); write_err != nil {
		return fmt.aprintf("could not write %s: %v", path, write_err), false
	}
	return "", true
}

parse_args :: proc(args: []string) -> (opts: Options, files: []string, ok: bool) {
	// One worker per PHYSICAL core, capped: 19 short parses do not reward hyperthreads, and an
	// undeterminable core count means one thread rather than a guess.
	cores := 1
	if physical, _, cores_ok := si.cpu_core_count(); cores_ok {
		cores = physical
	}
	opts = Options {
		jobs = clamp(cores, 1, 16),
	}
	collected := make([dynamic]string)
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch arg {
		case "--stdout":
			opts.to_stdout = true
		case "--lf":
			opts.lf = true
		case "--check-links":
			opts.check_links = true
		case "-h", "--help":
			fmt.println(USAGE)
			os.exit(0)
		case "--out-dir", "--jobs":
			if i + 1 >= len(args) {
				fmt.eprintfln("bml2html: %s needs a value", arg)
				return opts, nil, false
			}
			i += 1
			if arg == "--out-dir" {
				opts.out_dir = args[i]
			} else {
				count, parsed := strconv.parse_int(args[i])
				if !parsed || count < 1 {
					fmt.eprintfln("bml2html: --jobs %q is not a positive number", args[i])
					return opts, nil, false
				}
				opts.jobs = count
			}
		case:
			if strings.has_prefix(arg, "-") {
				fmt.eprintfln("bml2html: unknown option %q\n%s", arg, USAGE)
				return opts, nil, false
			}
			append(&collected, arg)
		}
	}
	return opts, collected[:], true
}

USAGE :: `usage: bml2html [options] [file.bml ...]

  no files            every *.bml in the working directory
  --out-dir DIR       where the .html go (default: the working directory, as bml2html.py did)
  --stdout            render ONE file to stdout, untranslated - the shape 'just parity' compares
  --lf                write LF endings instead of the platform's (Windows writes CRLF, as python did)
  --check-links       also report every [label](#Anchor) that no heading defines. Off by default: a
                      CHAPTER opened on its own links to headings in its sibling files on purpose,
                      so this is only meaningful on a root document that includes them
  --jobs N            worker threads (default: cores, capped at 16)`
