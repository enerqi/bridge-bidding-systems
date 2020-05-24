#! /usr/bin/doit -f
# https://pydoit.org
# `pip install [--user] doit` adds `doit.exe` to the PATH
# - Note `doit auto`, the file watcher only works on Linux/Mac
# - All commands are relative to dodo.py (doit runs in the working dir of dodo.py
#   even if ran from a different directory `doit -f path/to/dodo.py`)
from glob import glob
from os import environ
from os.path import abspath, basename, dirname, expanduser, join, splitext
from shutil import copyfile

from doit.tools import title_with_actions

home = expanduser("~")
bml_tools_dir = environ.get("BML_TOOLS_DIRECTORY", join(home, "dev/bml"))

def task_bml2html():
    """Create html file from bridge bidding markup language file."""
    bml2html_path = join(bml_tools_dir, "bml2html.py")
    input_bml_file_paths = glob("*.bml")

    def html_output_path(bml_path):
        return splitext(bml_path)[0] + ".html"

    for bml_path in input_bml_file_paths:
        yield {
            'name': basename(bml_path),
            'actions': [f"python {bml2html_path} {bml_path}"],
            'file_dep': [bml_path],  # stops unnecessary rebuilds
            'targets': [html_output_path(bml_path)],
            'title': title_with_actions
        }

def task_bmlcss():
    """Copy the bml CSS style sheet to this directory."""
    css_basename = "bml.css"
    src_css_file = join(bml_tools_dir, css_basename)

    def copy_file():
        # OS neutral compared to running a shell command
        copyfile(src_css_file, css_basename)

    return {
        'actions': [copy_file],
        'file_dep': [src_css_file],
        'targets': [css_basename],
        'title': title_with_actions
    }
