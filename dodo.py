#! /usr/bin/doit -f
# https://pydoit.org
# `pip install [--user] doit` adds `doit.exe` to the PATH
# - Note `doit auto`, the file watcher only works on Linux/Mac
# - All commands are relative to dodo.py (doit runs in the working dir of dodo.py
#   even if ran from a different directory `doit -f path/to/dodo.py`)
from glob import glob
import json
from os import environ
from os.path import abspath, basename, dirname, exists, expanduser, join, splitext
from shutil import copyfile
from typing import Iterator, List, NewType, Optional

from doit.tools import title_with_actions

Path = NewType("Path", str)

home = Path(expanduser("~"))
bml_tools_dir = Path(environ.get("BML_TOOLS_DIRECTORY", join(home, "dev/bml")))
bml_includes_cache_file = ".include-deps.json"


def bml_include_dependencies(bml_path: Path) -> List[Path]:
    # bml files can include others, so spend time scanning every bml file
    # for new include directives every time a bml file is saved
    def includes(file_handle) -> Iterator[Path]:
        for line in file_handle.readlines():
            line = line.strip()
            if line.startswith("#INCLUDE"):
                include_directive_tokens = line.split(maxsplit=1)
                if len(include_directive_tokens) > 1:
                    # We assume the file name is not quoted, just a free form path string
                    included_file = include_directive_tokens[1].strip()
                    yield Path(included_file)

    with open(bml_path, encoding='utf-8') as f:
        unique_deps = {include for include in includes(f) if include != bml_path}
        return list(unique_deps)


def read_bml_includes_cache(bml_path: Path) -> Optional[List[Path]]:
    if not exists(bml_includes_cache_file):
        return None

    with open(bml_includes_cache_file, encoding='utf-8') as f:
        try:
            existing_deps = json.load(f)
        except Exception:
            # Manually edited messed up json perhaps
            return None

        if bml_path in existing_deps:
            return existing_deps[bml_path]
        else:
            return None  # Manually edited perhaps (assuming we got the task order correct)


def update_bml_includes_cache(bml_path: Path, bml_deps: List[Path]):
    existing_deps = {}
    if exists(bml_includes_cache_file):
        with open(bml_includes_cache_file, encoding='utf-8') as f:
            try:
                existing_deps = json.load(f)
            except Exception:
                pass

    existing_deps[bml_path] = bml_deps

    with open(bml_includes_cache_file, "w", encoding='utf-8') as f:
        json.dump(existing_deps, f, indent=4)


def task_bml_include_cache():
    """Populate the bml include cache."""
    input_bml_file_paths = glob("*.bml")

    def calc_include_deps_and_cache(file_dep) -> None:
        bml_path = Path(file_dep)
        bml_deps = bml_include_dependencies(bml_path)
        update_bml_includes_cache(bml_path, bml_deps)

    for bml_path in input_bml_file_paths:
        # We don't use a target as doit cannot deal with more than one input file affecting the same output file
        # and we are using a single cache file instead of one cache file per input file.
        # This does mean that we are using the order of the tasks in this file to have the include cache updated
        # before the html task reads the include cache as part of determining changing file dependencies
        # The html task itself cannot use the include cache file as a doit file_dep dependency as it is being updated
        # by other unrelated bml file changes.
        # Actually, using a different notion of an update (not just tracking file modifications) if another feature of
        # doit that could be applied if interested enough.
        yield {
            'name': basename(bml_path),
            'actions': [(calc_include_deps_and_cache, [bml_path])],
            'file_dep': [bml_path],
            'title': title_with_actions
        }


def task_bml2html():
    """Create html file from bridge bidding markup language file."""
    bml2html_path = Path(join(bml_tools_dir, "bml2html.py"))
    input_bml_file_paths = glob("*.bml")

    def html_output_path(bml_path: Path) -> Path:
        return Path(splitext(bml_path)[0] + ".html")

    for bml_path in input_bml_file_paths:
        bml_deps = read_bml_includes_cache(bml_path)
        if bml_deps is None:
            bml_deps = bml_include_dependencies(bml_path)
            update_bml_includes_cache(bml_path, bml_deps)

        yield {
            'name': basename(bml_path),
            'actions': [f"python {bml2html_path} {bml_path}"],
            'file_dep': [bml_path] + bml_deps,
            'targets': [html_output_path(bml_path)],
            'title': title_with_actions
        }


def task_bmlcss():
    """Copy the bml CSS style sheet to this directory."""
    css_basename = "bml.css"
    src_css_file = Path(join(bml_tools_dir, css_basename))

    def copy_file() -> None:
        # OS neutral compared to running a shell command
        copyfile(src_css_file, css_basename)

    return {
        'actions': [copy_file],
        'file_dep': [src_css_file],
        'targets': [css_basename],
        'title': title_with_actions
    }


def task_publish_bidding_systems():
    """Copy the main bidding html and css document to the web server root."""
    swedish_file = "bidding-system.html"
    dst_swedish = f"W:/{swedish_file}"
    css_file = "bml.css"
    dst_css = f"W:/{css_file}"
    scanian_file = "scanian-natural.html"
    dst_scanian = f"W:/{scanian_file}"
    bboalert_file = "weak-strong-club.bboalert"
    dst_bboalert = f"W:/{bboalert_file}"
    u16_squad_file = "squad-system.html"
    dst_u16 = f"w:/{u16_squad_file}"
    improvements_file = "youth-improvements.html"
    dst_improvements = f"w:/{improvements_file}"

    alternatives_file = "alternatives.html"
    dst_alternatives = f"w:/{alternatives_file}"

    def copy_file(dependencies, targets) -> None:
        copyfile(dependencies[0], targets[0])

    for src, dst in [(swedish_file, dst_swedish), (css_file, dst_css),
                     (scanian_file, dst_scanian), (bboalert_file, dst_bboalert),
                     (u16_squad_file, dst_u16), (improvements_file, dst_improvements),
                     (alternatives_file, dst_alternatives)]:
        yield {
            'name': basename(src),
            'actions': [copy_file],
            'file_dep': [src],
            'targets': [dst],
            'title': title_with_actions
        }
