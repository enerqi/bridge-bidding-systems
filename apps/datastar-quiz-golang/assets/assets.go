// Package assets is the app's static files, embedded so the binary is the deployment.
//
// `static/` is copied verbatim from `apps/datastar-quiz/static/` (the three stylesheets, the
// game-feel layer and the vendored datastar bundle plus its source map); `media/` holds the
// one image the completion screen shows, which lives with the panel app and is served
// read-only.
//
// It is a package of its own, at the top of the app rather than inside internal/web, for one
// mechanical reason: `go:embed` patterns are relative to the package directory, so the files
// have to sit beside a .go file. Putting that file here keeps the assets where somebody
// editing a stylesheet would look for them.
package assets

import "embed"

// Static is `/static/...`: the stylesheets and the datastar bundle.
//
//go:embed all:static
var Static embed.FS

// Media is `/media/...`: the completion screen's image.
//
//go:embed all:media
var Media embed.FS
