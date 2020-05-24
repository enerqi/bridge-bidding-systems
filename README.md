# Contract Bridge Bidding System

Bridge system notes written with BML.
Html can be generated from the `.bml` files using the bml tools.

## Workflow Setup

- Download the [BML tools](https://github.com/enerqi/bml) and this repository.
- Install [Python v3](https://www.python.org/) programming language, preferrably not system wide to make permissions
  easier and make sure Python 3 is added to `PATH` via the installer options.
- Install [doit](https://pydoit.org) from public Python packages repository: `pip install --user doit`
  If `pip` is not found then the `Scripts` directory needs adding to the `PATH` environment variable, e.g. the
  `C:/Users/$MyUser/AppData/Roaming/Python/Python38/Scripts/` directory if Python 3.8 was installed. `pip` should be
  in there (using the correct `MyUser` replacement). The `doit` program will be installed to the same directory
  as `pip`.
- Install [watchexec](https://github.com/watchexec/watchexec) as per the instructions and ensure it's in the `PATH`
  To install with `cargo` when you don't have `cargo`, use [rustup](https://rustup.rs/) to install the Rust tooling
  ecosystem. Otherwise use one of the other suggestions.

All the programs `doit`, `python`, and `watchexec` should be found from a command prompt (shell) at this point.

The bml tools should be specified by one of two ways:
- downloaded to the `dev/bml` directory within your home (user) directory, e.g. `C:/Users/MyUser/dev/bml`
- Setting an environment variable `BML_TOOLS_DIRECTORY` with the directory as the value

With those in place it should be possible to run a workflow that trys to build `html` files from your bridge `bml`
files everytime you save changes to a bml file in this directory. Open a command prompt (shell) in this directory:

```shell

cd bridge-bidding-systems
watchexec --exts bml doit
```

- Watchexec is now monitoring this directory for any file system changes to files with the extension `.bml`.
- Whenever a change is found the `doit` program is run
- `doit` looks at `dodo.py` and runs all the tasks in there.

The `dodo.py` task automation program uses the `bml2html.py` python program found in the bml tools.

### Live Web Page (HTML) View

So far, whenever a `.bml` file is saved, the html output is rebuilt. This can be viewed in a browser but normally you
have to manually refresh the browser page to see any changes in the html as you are editing the bml file(s).
There's probably a number of reasonable approaches to this. The most convenient for myself was to open this
`bridge-bidding-system` directory in [Visual Studio Code](https://code.visualstudio.com/), install the
[Live Server](https://marketplace.visualstudio.com/items?itemName=ritwickdey.LiveServer) extension for VSCode and open
a generated html file with the live server (command `Live Server: Open with Live Server`). At that point any web
browser can pointed to `http://127.0.0.1:5500/` and you will see any viewed html file live reload as changes are made.

## Comments on BML Tool Usage

The [BML tools](https://github.com/enerqi/bml) have my own changes applied to the
[main BML tools](https://github.com/Kungsgeten/bml) repository. E.g. the html files have a `.html` extension instead
of `.htm`.

Something about the CUT/PASTE bml feature is difficult. Pasting bml modules to nested (indented) positions in bidding
tables seems incomplete. However, unindenting 2 extra to the left on the line following a #PASTE directive seems
to fix it.
