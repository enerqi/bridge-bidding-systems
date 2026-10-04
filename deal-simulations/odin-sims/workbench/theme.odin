package main

/*
	theme.odin — dark, light, or whatever Windows is set to; and the preferences view that chooses.

	HOW A THEME IS APPLIED. Every colour in `ui/workbench.css` is a token on `:root` (the dark set), and
	`html[theme="light"]` redefines the same tokens — so a theme is ONE attribute on the root element and no
	stylesheet is swapped. One engine fact makes it work and is easy to miss, measured in the windowless
	harness: changing that attribute recolours the root at once, but its DESCENDANTS keep the colours they
	resolved before (a ghost button stayed `#CDD6F4` after its `--ink` had become `#4C4F69`) until the tree is
	restyled. `update_element(root, render = true)` is that restyle, and `apply_theme` always does it. It
	does not reach a HIDDEN view, though, and the settings view hides them all — so every view not on screen
	is marked stale and `show_view` restyles it when it is next shown.

	THE HOSTED PAGES ARE NOT THEMED. The BML preview and the card page bring their own (light) stylesheets
	inside a `<frame>`, and they are the published pages — what a reader on `w:/deals/` sees. Theming them
	would make the preview stop being a preview.

	`system` IS READ ONCE, when the theme is applied: Windows' own app-mode switch
	(`HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, `AppsUseLightTheme`). Following a
	change live would mean listening for `WM_SETTINGCHANGE`, which this window does not see — the engine owns
	the message loop. Choosing `system` again, or restarting, picks the change up.
*/

import "core:fmt"
import win "core:sys/windows"

import "../prefs"
import sa "sciter:sciter_app"

Theme :: enum {
	Dark,
	Light,
	System,
}

// Where the choice is remembered. The value is the word the preferences view's buttons carry.
THEME_PREF :: "theme"

theme_word :: proc(theme: Theme) -> string {
	switch theme {
	case .Dark:
		return "dark"
	case .Light:
		return "light"
	case .System:
		return "system"
	}
	return "dark"
}

theme_of :: proc(word: string) -> (theme: Theme, ok: bool) {
	switch word {
	case "dark":
		return .Dark, true
	case "light":
		return .Light, true
	case "system":
		return .System, true
	}
	return .Dark, false
}

// The remembered choice. DARK when nothing is remembered, because that is how this window has always
// looked and a first start should not surprise anybody.
chosen_theme :: proc(app: ^App) -> Theme {
	word, found := prefs.get(&app.prefs, THEME_PREF)
	if !found {
		return .Dark
	}
	theme, _ := theme_of(word)
	return theme
}

/*
Does Windows want apps light? Read from the registry value the Settings app writes. ANY failure — no key,
an older Windows, another OS — answers dark, the window's own default, rather than guessing light.
*/
system_prefers_light :: proc() -> bool {
	when ODIN_OS != .Windows {
		return false
	} else {
		value: win.DWORD
		size := win.DWORD(size_of(value))
		status := win.RegGetValueW(
			win.HKEY_CURRENT_USER,
			win.L(`Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`),
			win.L("AppsUseLightTheme"),
			win.RRF_RT_REG_DWORD,
			nil,
			&value,
			&size,
		)
		return status == 0 && value != 0
	}
}

// Dark or light, with `system` resolved.
effective_theme :: proc(theme: Theme) -> Theme {
	if theme == .System {
		return .Light if system_prefers_light() else .Dark
	}
	return theme
}

// Put `theme` on the window: the attribute, then the restyle the descendants need (see the header).
apply_theme :: proc(app: ^App, theme: Theme) {
	root, err := sa.root(app.window)
	if err != nil || root == nil {
		return
	}
	// Always SET, never removed (the bindings have no remove): the stylesheet matches only `light`, so
	// `dark` is the default tokens by not matching anything.
	sa.set_attribute(root, "theme", "light" if effective_theme(theme) == .Light else "dark")
	_ = sa.update_element(root, render = true)
	// AND EVERY VIEW NOT ON SCREEN IS NOW STALE. The restyle above does not reach a hidden subtree: a view
	// hidden at this moment kept the previous theme's colours when it was shown again (measured), and the
	// settings view hides every working view, so that was every theme change. `show_view` restyles each
	// of these on its first showing.
	app.theme_stale = ~bit_set[View]{} - {current_view(app)}
	draw_prefs(app)
}

// A theme button was pressed: remember it, and show it.
choose_theme :: proc(app: ^App, theme: Theme) {
	if app.prefs.values != nil {
		prefs.set(&app.prefs, THEME_PREF, theme_word(theme))
		if app.prefs_path != "" {
			_ = prefs.save(&app.prefs, app.prefs_path)
		}
	}
	apply_theme(app, theme)
}

// ---------------------------------------------------------------------------------------------------
// The preferences view
//
// The shape of About and the keys list: a reference errand entered from anywhere (the gear in the header),
// replacing the panes rather than floating over them, and left by going back to where you were — `close`,
// escape or ctrl+w.

show_prefs :: proc(app: ^App, shown: bool) {
	if shown {
		app.before_prefs = current_view(app)
		show_view(app, .Prefs)
		draw_prefs(app)
		return
	}
	show_view(app, app.before_prefs)
}

// Light the button of the remembered choice, and say what `system` currently resolves to.
draw_prefs :: proc(app: ^App) {
	theme := chosen_theme(app)
	for candidate in Theme {
		button := find(app, fmt.tprintf(`#prefs-panel [data-theme="%s"]`, theme_word(candidate)))
		if button == nil {
			continue
		}
		if candidate == theme {
			sa.set_attribute(button, "class", "segbtn on")
		} else {
			sa.set_attribute(button, "class", "segbtn")
		}
	}
	system := "light" if system_prefers_light() else "dark"
	set_text_at(app, "#prefs-theme-note", fmt.tprintf("system is currently %s", system))
}
