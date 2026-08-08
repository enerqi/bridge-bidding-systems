"""Reading a `light-dark()` stylesheet from a test.

The palettes used to be two blocks -- a light `:root` and a `@media (prefers-color-scheme: dark)`
copy -- so a test could pick one by splitting the file at the media query. They are now one block of
`light-dark(<light>, <dark>)` pairs, because a media query answers to the OS and nothing else and the
app has a manual theme toggle (see the theme switch note in `app.css`). So "the dark palette" is no
longer a region of the file; it is one side of every pair, and this module is the resolver.

Shared by `test_surfaces.py`, `test_suit_colours.py` and `test_elevation_and_type.py`, which all used
to carry their own copy of the split.
"""

from __future__ import annotations

import re
from pathlib import Path

import render

STATIC = Path(render.__file__).resolve().parent / "static"
SHEETS = ("app.css", "app-pico.css", "app-bulma.css")


def source(name: str) -> str:
    return (STATIC / name).read_text(encoding="utf-8")


def strip_comments(css: str) -> str:
    return re.sub(r"/\*.*?\*/", "", css, flags=re.DOTALL)


def _split_args(inner: str) -> list[str]:
    """Top-level comma split -- the arguments can be `color-mix(in srgb, x, y)` themselves."""
    depth, out, current = 0, [], ""
    for char in inner:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if char == "," and depth == 0:
            out.append(current.strip())
            current = ""
        else:
            current += char
    out.append(current.strip())
    return out


def resolve(value: str, *, dark: bool) -> str:
    """`value` with every `light-dark(a, b)` collapsed to one side, innermost first."""
    while (start := value.find("light-dark(")) != -1:
        depth, i = 0, start + len("light-dark(") - 1
        while True:
            if value[i] == "(":
                depth += 1
            elif value[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        args = _split_args(value[start + len("light-dark(") : i])
        assert len(args) == 2, f"light-dark() takes two arguments: {value}"
        value = value[:start] + args[1 if dark else 0] + value[i + 1 :]
    return " ".join(value.split())


def declaration(css: str, name: str, *, dark: bool) -> str | None:
    """The first declared value of `name`, resolved for one palette. None if it is not declared."""
    match = re.search(rf"(?<![\w-]){re.escape(name)}:\s*([^;]+);", strip_comments(css))
    return resolve(match.group(1), dark=dark) if match else None


def token(sheet: str, name: str, *, dark: bool) -> str:
    value = declaration(source(sheet), name, dark=dark)
    assert value is not None, f"{sheet}: {name} is not declared"
    return value


def hex_tokens(sheet: str, *, dark: bool) -> dict[str, str]:
    """Every custom property whose value resolves to a plain hex colour, for one palette."""
    css = strip_comments(source(sheet))
    out: dict[str, str] = {}
    for name, raw in re.findall(r"(--[a-z-]+):\s*([^;]+);", css):
        if name in out:
            continue  # the first declaration wins, as it did when the palettes were two blocks
        value = resolve(raw, dark=dark)
        if re.fullmatch(r"#[0-9a-fA-F]{3,8}", value):
            out[name] = value
    return out
