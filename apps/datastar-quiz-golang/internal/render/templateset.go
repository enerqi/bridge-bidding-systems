package render

import (
	"fmt"
	"html/template"
	"io/fs"
	"path"
	"regexp"
	"strings"
	"sync"
)

// THE MOUNT PREFIX IS SUBSTITUTED INTO THE TEMPLATE SOURCE, NOT INTERPOLATED PER RENDER.
//
// It looks like an odd choice until you meet the escaper. html/template decides an
// attribute's content type from its NAME, and after stripping the `data-` prefix every
// `data-on:*` attribute begins with "on" -- so datastar's event expressions are treated as
// JavaScript, which is correct. The consequence is that a value interpolated inside one of
// those expressions goes through the JS string escaper, and that escaper rewrites `/` as
// `\/` (both tables do; `template.JSStr` does not exempt it).
//
// To a browser that is the same string: `'\/skip'` is `'/skip'`. To the LOAD HARNESS it is
// not. `apps/dsquiz-perf/common/datastar.py` reads the mount prefix straight out of the
// markup with a regex, so a prefixed deployment would hand it `\/bridge-system-quiz` and
// every request in the run would go to a path with a backslash in it. The python emits a
// plain slash (jinja escapes for HTML only), and the two implementations have to be driven
// by the same harness or the comparison is not one.
//
// So the prefix -- which is process-wide configuration read once from the environment, not
// per-request data -- is spliced into the template TEXT before html/template parses it. It
// is then literal markup, which is exactly what it is in the python. One template set per
// distinct prefix, built once and cached; in a server there is exactly one.
//
// The substituted values are validated below, because splicing into template source is only
// safe for values that cannot contain template syntax.

var (
	prefixToken     = "{{ .Prefix }}"
	dollarToken     = "{{ $.Prefix }}"
	cookiePathToken = "{{ .CookiePath }}"
)

// safePrefix is what a mount prefix may contain. Deliberately narrow: this string is
// spliced into template source, and a prefix is a path segment somebody typed into an env
// var, not free text.
var safePrefix = regexp.MustCompile(`^(/[A-Za-z0-9_.~-]+)*$`)

// ValidatePrefix reports whether a mount prefix is one this app will splice into its
// templates. Called at startup so a bad value is a refusal to boot rather than a page.
func ValidatePrefix(prefix string) error {
	if !safePrefix.MatchString(prefix) {
		return fmt.Errorf("mount prefix %q must be empty or one or more /segments of [A-Za-z0-9_.~-]", prefix)
	}
	return nil
}

var (
	setsMu sync.Mutex
	sets   = map[string]*template.Template{}
	// the raw sources, read once
	sourcesOnce sync.Once
	sources     map[string]string
)

func readSources() map[string]string {
	sourcesOnce.Do(func() {
		sources = map[string]string{}
		entries, err := fs.ReadDir(templateFS, "templates")
		if err != nil {
			panic("templates: " + err.Error())
		}
		for _, entry := range entries {
			body, err := templateFS.ReadFile("templates/" + entry.Name())
			if err != nil {
				panic("templates: " + err.Error())
			}
			sources[entry.Name()] = string(body)
		}
	})
	return sources
}

// templatesFor is the template set for one mount prefix.
func templatesFor(prefix string) *template.Template {
	setsMu.Lock()
	defer setsMu.Unlock()
	if set, ok := sets[prefix]; ok {
		return set
	}
	cookiePath := prefix
	if cookiePath == "" {
		cookiePath = "/"
	}
	replacer := strings.NewReplacer(
		prefixToken, prefix,
		dollarToken, prefix,
		cookiePathToken, cookiePath,
	)
	set := template.New("").Funcs(funcs)
	for name, body := range readSources() {
		if _, err := set.New(path.Base(name)).Parse(replacer.Replace(body)); err != nil {
			panic("template " + name + ": " + err.Error())
		}
	}
	sets[prefix] = set
	return set
}
