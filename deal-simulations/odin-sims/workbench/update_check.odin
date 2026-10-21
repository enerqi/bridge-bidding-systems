package main

/*
	The version, and "is a newer release out?" - asked BY HAND, from the About panel.

	The version is stamped at build time: `just sims dist 0.1.0-alpha.1` passes
	`-define:WORKBENCH_VERSION=0.1.0-alpha.1`; every other build says "dev".

	The check is one HTTPS GET of the GitHub releases list, on a thread of its own, when the person presses
	`check for a new version` - never at startup and never on a timer: a program that phones home by itself
	is a thing to explain, and an alpha's users can press a button. It asks for the newest release INCLUDING
	pre-releases (`/releases?per_page=1`, newest first): `/releases/latest` skips anything marked
	pre-release, which is every release while this is alpha, so it would answer "nothing published".

	Through libcurl (`vendor:curl`, shipped with Odin, static, TLS by Windows' own Schannel): about 1MB of
	exe, measured, and it is the same code on Linux. The answer is turned into a sentence by `release_news`,
	which has no network in it, so the tests cover every wording without one.
*/

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import sa "sciter:sciter_app"
import curl "vendor:curl"

WORKBENCH_VERSION :: #config(WORKBENCH_VERSION, "dev")

// Where releases are published. One place, so moving the releases to another repository is one edit.
RELEASES_API :: "https://api.github.com/repos/enerqi/bridge-bidding-systems/releases?per_page=1"
RELEASES_PAGE :: "https://github.com/enerqi/bridge-bidding-systems/releases"

// The version as the About panel words it.
version_label :: proc() -> string {
	return WORKBENCH_VERSION == "dev" ? "development build" : fmt.tprintf("version %s", WORKBENCH_VERSION)
}

/*
Compare two versions: negative when `a` is older than `b`, 0 when the same, positive when newer. A leading
`v` is ignored (`v0.2.0` is `0.2.0`), missing parts count as 0 (`1.2` is `1.2.0`), and a pre-release is older
than its release (`0.1.0-alpha.2` < `0.1.0`), its dot-separated parts compared as numbers where both are
numbers and as text otherwise - semver's rules, which `alpha.2` < `alpha.10` < `beta` follows.
*/
version_compare :: proc(a, b: string) -> int {
	split :: proc(version: string) -> (core, pre: string) {
		v := strings.trim_prefix(strings.trim_space(version), "v")
		if plus := strings.index_byte(v, '+'); plus >= 0 {
			v = v[:plus] // build metadata never orders
		}
		if dash := strings.index_byte(v, '-'); dash >= 0 {
			return v[:dash], v[dash + 1:]
		}
		return v, ""
	}
	// One dot-separated part against another: numerically when both are numbers.
	part_compare :: proc(x, y: string) -> int {
		nx, x_is := strconv.parse_int(x)
		ny, y_is := strconv.parse_int(y)
		switch {
		case x_is && y_is:
			return nx - ny
		case x_is:
			return -1 // a numeric identifier orders before a word
		case y_is:
			return 1
		}
		return strings.compare(x, y)
	}
	a_core, a_pre := split(a)
	b_core, b_pre := split(b)
	xs := strings.split(a_core, ".", context.temp_allocator)
	ys := strings.split(b_core, ".", context.temp_allocator)
	for i in 0 ..< max(len(xs), len(ys)) {
		x := i < len(xs) ? xs[i] : "0"
		y := i < len(ys) ? ys[i] : "0"
		if d := part_compare(x, y); d != 0 {
			return d
		}
	}
	switch {
	case a_pre == b_pre:
		return 0
	case a_pre == "":
		return 1 // the release is newer than any of its pre-releases
	case b_pre == "":
		return -1
	}
	ps := strings.split(a_pre, ".", context.temp_allocator)
	qs := strings.split(b_pre, ".", context.temp_allocator)
	for i in 0 ..< min(len(ps), len(qs)) {
		if d := part_compare(ps[i], qs[i]); d != 0 {
			return d
		}
	}
	return len(ps) - len(qs)
}

/*
GitHub's answer -> the sentence for the About panel, and the page to offer ("" for none). `status` is the
HTTP status (0 when no answer came back, with `failure` saying why); `body` is the JSON list of releases,
newest first. Allocated in `allocator`.
*/
release_news :: proc(current: string, status: int, body: string, failure: string, allocator := context.allocator) -> (text: string, url: string) {
	if status == 0 {
		return fmt.aprintf("could not reach GitHub: %s", failure, allocator = allocator), ""
	}
	if status != 200 {
		return fmt.aprintf("GitHub answered %d - try again later", status, allocator = allocator), strings.clone(RELEASES_PAGE, allocator)
	}
	Release :: struct {
		tag_name:   string,
		html_url:   string,
		prerelease: bool,
	}
	releases: []Release
	if err := json.unmarshal(transmute([]u8)body, &releases, allocator = context.temp_allocator); err != nil {
		return strings.clone("GitHub's answer could not be read", allocator), strings.clone(RELEASES_PAGE, allocator)
	}
	if len(releases) == 0 {
		return strings.clone("no release has been published yet", allocator), ""
	}
	newest := releases[0]
	tag := strings.trim_prefix(newest.tag_name, "v")
	page := newest.html_url != "" ? newest.html_url : RELEASES_PAGE
	kind := newest.prerelease ? " (pre-release)" : ""
	switch {
	case current == "dev":
		return fmt.aprintf("this is a development build; the newest release is %s%s", tag, kind, allocator = allocator),
			strings.clone(page, allocator)
	case version_compare(tag, current) > 0:
		return fmt.aprintf("%s%s is out - you have %s", tag, kind, current, allocator = allocator), strings.clone(page, allocator)
	}
	return fmt.aprintf("you have the newest release (%s)", current, allocator = allocator), ""
}

// One HTTPS GET: the status (0 if no answer) and body, or why it failed. Worker-side; blocks up to 15s.
http_get :: proc(url: string, allocator := context.allocator) -> (status: int, body: string, failure: string) {
	handle := curl.easy_init()
	if handle == nil {
		return 0, "", "libcurl did not start"
	}
	defer curl.easy_cleanup(handle)

	received := strings.builder_make(allocator)
	on_write :: proc "c" (buffer: [^]byte, size, count: uint, user: rawptr) -> uint {
		context = runtime.default_context()
		into := (^strings.Builder)(user)
		n := size * count
		strings.write_bytes(into, buffer[:n])
		return n
	}
	curl.easy_setopt(handle, .URL, strings.clone_to_cstring(url, context.temp_allocator))
	curl.easy_setopt(handle, .USERAGENT, cstring("bridge-workbench")) // GitHub refuses requests without one
	curl.easy_setopt(handle, .WRITEFUNCTION, on_write)
	curl.easy_setopt(handle, .WRITEDATA, &received)
	curl.easy_setopt(handle, .CONNECTTIMEOUT_MS, i32(8000))
	curl.easy_setopt(handle, .TIMEOUT_MS, i32(15000))
	curl.easy_setopt(handle, .FOLLOWLOCATION, i32(1))
	if result := curl.easy_perform(handle); result != .E_OK {
		strings.builder_destroy(&received)
		return 0, "", fmt.aprintf("%v", result, allocator = allocator)
	}
	code: i32
	curl.easy_getinfo(handle, .RESPONSE_CODE, &code)
	return int(code), strings.to_string(received), ""
}

// The About panel's button. Engine-thread. A second press while one is in flight does nothing.
start_update_check :: proc(app: ^App) {
	if app.update_thread != nil {
		if !thread.is_done(app.update_thread) {
			return
		}
		thread.join(app.update_thread)
		thread.destroy(app.update_thread)
		app.update_thread = nil
	}
	set_text_at(app, "#about-update-status", "asking GitHub…")
	set_shown(app, "#about-update-link", false)
	app.update_thread = thread.create_and_start_with_poly_data(app, proc(app: ^App) {
		status, body, failure := http_get(RELEASES_API, context.temp_allocator)
		text, url := release_news(WORKBENCH_VERSION, status, body, failure)
		sync.lock(&app.mutex)
		delete(app.update_text)
		delete(app.update_found_url)
		app.update_text, app.update_found_url = text, url
		sync.unlock(&app.mutex)
		free_all(context.temp_allocator)
		sa.post_callback(app.window, UPDATE)
	})
}

// UPDATE arrived: show the sentence, and the release page's link when there is one. Engine-thread.
show_update_news :: proc(app: ^App) {
	sync.lock(&app.mutex)
	text := strings.clone(app.update_text, context.temp_allocator)
	delete(app.update_url, app.allocator)
	app.update_url = strings.clone(app.update_found_url, app.allocator)
	sync.unlock(&app.mutex)
	set_text_at(app, "#about-update-status", text)
	set_shown(app, "#about-update-link", app.update_url != "")
}

// Shutdown: a check still in flight is waited for (curl's own timeouts bound it).
stop_update_check :: proc(app: ^App) {
	if app.update_thread != nil {
		thread.join(app.update_thread)
		thread.destroy(app.update_thread)
		app.update_thread = nil
	}
	delete(app.update_text)
	delete(app.update_found_url)
	delete(app.update_url, app.allocator)
}
