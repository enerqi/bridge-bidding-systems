# Deploying the quiz apps behind nginx

Written against the live `sublime.is` config (FreeBSD, nginx + supervisord, TLS from letsencrypt).
Covers the **panel** quiz that is already deployed and the **datastar** quiz that is taking over its
URL, because the two need different things from the proxy and the differences are the interesting
part.

**Status: deployed and serving `/bridge-system-quiz/`.** Verified through the live proxy:

- **SSE is not buffered** — `just dsquiz measure --base https://sublime.is/bridge-system-quiz` reports
  `chunk arrivals (ms): [6, 10, 624, 639, 640]`, `spread 634 ms over 5 chunks -- paced`. The 614ms gap
  is the server-side sleep surviving nginx; buffered, all five land together. Document 23.5KB → 5.1KB
  brotli, and `content-encoding: br` on the stream itself, so nginx passes it through untouched.
- **Cookie affinity holds** — six requests carrying one `dsq_sid` all reached `…:6011`.

Left over: log rotation for `/var/log/bridge-quiz-ds.log`, and the `X-Upstream` header removed again
(or `$upstream_addr` moved into `log_format main`, which is worth keeping).

Section 4 is the walkthrough; sections 1-3 are why it looks the way it does.

---

## 1. What runs where

| app | framework | port(s) | mounted at | state |
|---|---|---|---|---|
| bidding quiz | panel/bokeh | 6005, 6006, 6007 | `/bridge-system-quiz/` | Bokeh Document per **websocket**, in-process |
| optimal point count | panel/bokeh | 6001, 6002 | `/opc/` | same |
| bidding quiz (datastar) | litestar/uvicorn | 6011-6013 | `/bridge-system-quiz/` — **taking this over** | `Session` dict per **cookie**, in-process |

The datastar app becoming the default quiz means it answers `/bridge-system-quiz/`, the URL players
already have, and the panel app moves aside (a spare path, or stopped). Nothing about the app
changes for that: it is the same `DSQUIZ_PREFIX` mechanism as any other subpath, with
`bridge-system-quiz` as the value.

Everything is single-process-per-port and process-local, so **all three need session affinity** as
long as they run more than one process. Section 5 is how to stop needing it.

---

## 2. The panel apps

### The two shapes of "3 processes", and why it matters

- **`panel serve --num-procs 3`** — Bokeh forks three workers sharing **one** listening socket. The
  kernel decides which worker accepts a connection, so `upstream` has a single `server` entry and
  **nginx cannot do affinity at all**. `--reuse-sessions` cannot work in this shape.
- **three `panel serve --num-procs 1` on three ports, under supervisord** — three `server` entries,
  and affinity becomes possible. This is the shape to be in, and what the config below assumes.

### What is actually live (read the real `nginx.conf` before trusting the block below)

The deployed panel quiz does **not** use the keep-the-prefix arrangement this section recommends. It
strips instead, and the pieces fit together like this:

- `location ^~ /bridge-system-quiz/ { proxy_pass http://panel_app/; }` — **trailing slash**, so
  nginx removes `/bridge-system-quiz/` and panel receives `/`.
- the supervisord command passes no `--prefix` and no `--use-xheaders`, which is the other half of
  the same choice: panel genuinely is mounted at its root.
- `proxy_set_header Connection "upgrade"` is hardcoded (no `map`), the mistake listed below.
- `http{}` sets `send_timeout 9s` globally, and nothing turns `proxy_buffering` off anywhere.

Those last two are inherited by any new `location`, which is why the datastar block in §3 sets both
explicitly. The `/opc/` location is the same shape as the panel one.

### nginx (the keep-the-prefix shape, for reference)

```nginx
# in http{} — send the upgrade header only when the client actually asked for one
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

upstream panel_app {
    ip_hash;                          # affinity, keyed on the client IP
    server www.sublime.is:6005;
    server www.sublime.is:6006;
    server www.sublime.is:6007;
}

location ^~ /bridge-system-quiz/ {
    proxy_pass http://panel_app;      # NO trailing slash: keep the prefix (see below)
    proxy_http_version 1.1;
    proxy_set_header Upgrade    $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    # server-level proxy_read_timeout/proxy_send_timeout of 900s are inherited and are what a
    # mostly-idle websocket needs; Bokeh pings roughly every 37s
}
```

Three things that are easy to get wrong:

1. **The trailing slash on `proxy_pass`.** `http://panel_app/` *strips* `/bridge-system-quiz/`, so
   panel believes it is mounted at the root and emits root-absolute URLs for its own assets and
   websocket — which the browser then requests outside this `location`, hitting whatever serves `/`.
   Either keep the prefix (no slash) **and** launch panel with `--prefix bridge-system-quiz`, or strip
   it and separately route every asset path panel emits. The first is the maintainable one.
2. **`Connection "upgrade"` hardcoded** sends `Connection: upgrade` on ordinary requests too, with an
   empty `Upgrade`. Tornado tolerates it; it is still wrong and it defeats upstream keepalive. Use the
   `map` above.
3. **`--allow-websocket-origin` / `--use-xheaders`.** Behind a proxy, Bokeh rejects the websocket
   handshake unless the origin is allowed. `--use-xheaders` makes it trust `X-Forwarded-Proto`, which
   this config already sends, so `wss://` is built correctly.

### supervisord

```ini
[program:bridge-quiz-panel]
command=/usr/local/bin/uv run --project /path/to/repo panel serve
        /path/to/repo/apps/quiz/quiz_app.py
        --port %(process_num)s
        --prefix bridge-system-quiz
        --use-xheaders
        --allow-websocket-origin=sublime.is
        --num-procs 1
process_name=%(program_name)s_%(process_num)s
numprocs=3
numprocs_start=6005
directory=/path/to/repo
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www
stdout_logfile=/var/log/panel-quiz-%(process_num)s.log
redirect_stderr=true
```

`--port %(process_num)s` with `numprocs_start=6005` gives 6005/6006/6007 from one program block.
Repeat for the OPC app on 6001-6002.

Note `/path/to/repo` is aspirational: what is actually deployed is `/quiz-u16`, the flattened
directory `just deploy-quiz` writes (app modules, corpus and `bml/` all in one place, plus the root
`pyproject.toml`/`uv.lock` — its venv is named `bridge-bidding-apps` after that project). Substitute
`/quiz-u16` and `/quiz-u16/quiz_app.py`. The datastar app cannot use that flat shape; §4.1 says why.

---

## 3. The datastar app

It needs **less** than panel (no websocket) and one thing more (SSE must not be buffered). It can
also do affinity properly, because it has its own cookie.

### The plan: take over `/bridge-system-quiz/`

Stripped to the directives, to talk about them. §4.4 has the same blocks commented in the config's
own idiom — paste from there, not here.

```nginx
upstream ds_quiz {
    hash $cookie_dsq_sid consistent;   # cookie affinity, nginx OSS (>=1.7.2)
    server www.sublime.is:6011;        # SAME ADDRESS THE APP BINDS -- see below
    server www.sublime.is:6012;
    server www.sublime.is:6013;
}

location ^~ /bridge-system-quiz/ {
    proxy_pass http://ds_quiz;         # NO trailing slash -- the app expects the prefix
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Connection "";     # plain HTTP + SSE, never a websocket

    proxy_buffering off;                # REQUIRED, see below
    proxy_cache off;
    proxy_read_timeout 900s;
    send_timeout 900s;                  # overrides the global 9s for held streams
}
```

The `Upgrade` / `$connection_upgrade` pair the panel location needs must **go**: there is no
websocket here, and `Connection ""` is what lets upstream keepalive work.

**The address is a real decision, not boilerplate.** `127.0.0.1` is wrong on this box — the panel
`upstream` already dials `www.sublime.is:600x` rather than loopback, and this app has to be reachable
the same way. Whatever the app binds (`--host`) and whatever nginx dials (`server …`) must be the
same address, and both must be an address nginx can actually reach from where *it* runs. Bind
`0.0.0.0` if unsure — it covers every interface, so nginx reaches it however it asks — but note that
this also puts ports 6011-6013 in front of anyone who can route to the box, with no TLS and no
prefix-stripping. If a packet filter fronts the box, the tidy version is to bind the one interface
address nginx uses and block 6011-6013 from outside.

`^~` beats the panel's regex locations if any exist; with two prefix locations, the longest match
wins, so a `/bridge-system-quiz/` block and a `/bridge-system-quiz-panel/` block coexist happily
while the panel app is parked.

### Alternative — its own host (zero prefix work)

Worth knowing about, because it is the shape with the fewest moving parts if the panel app is ever
retired rather than parked: point a hostname at the same `ds_quiz` upstream, mount at the root, drop
`DSQUIZ_PREFIX` entirely. Needs DNS and a name on the certificate.

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name quiz.sublime.is;       # must be on the certificate

    if ($host !~* ^(quiz\.sublime\.is)$) { return 444; }

    add_header Strict-Transport-Security 'max-age=31536000; includeSubDomains;';

    location / {
        proxy_pass http://ds_quiz;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";     # plain HTTP + SSE, never a websocket

        proxy_buffering off;                # REQUIRED, see below
        proxy_cache off;
        proxy_read_timeout 900s;
        send_timeout 900s;                  # overrides the global 9s for held streams
    }
}
```

Why cookie affinity beats `ip_hash` here: it survives a client IP change (mobile, VPN) and does not
collapse a whole NAT onto one worker. `consistent` means adding or removing a backend rehashes only
about 1/N of sessions instead of all of them. The very first request has no cookie and hashes on the
empty string — fine, that is the request that creates the session and sets the cookie.

`dsq_sid` identifies the **browser**, not one quiz: sessions are keyed by (browser, variant), so a
player can have the squad quiz and the swedish one going at once and each tab's own URLs say which is
which. That is deliberately still *one* cookie under *one* name — a name that varied by variant would
leave this directive hashing on a cookie half the requests do not carry, and the same browser would
bounce between workers depending on which tab it clicked in.

**`proxy_buffering off` is not optional.** The answer stream is deliberately paced with server-side
sleeps (toast, pause, toast, pause, then the new question). With buffering on, nginx holds the frames
and the player sees nothing for two or three seconds and then everything at once. `send_timeout` is
the maximum gap between two writes *to the client*; the global 9s is fine for the default client-side
timer but not for `DSQUIZ_TIMER=stream`.

Compression: the app brotli-compresses its own responses, including the SSE streams
(`CompressionConfig(backend="brotli", brotli_quality=5)`), and nginx passes that through untouched.
Do not add `gzip on` for this location — it cannot recompress brotli and has nothing to add.

### What `DSQUIZ_PREFIX` does, and why it is two things rather than one

- `Litestar(path=URL_PREFIX)` moves every route and both static routers. That is the routing half.
- The templates emit their own URLs (`@post('/answer/…')`, `<link href="/static/app.css">`), which are
  root-absolute. Under a prefix the browser would ask the **site root** for them: the stylesheet would
  come back as a 404 from the static file server and every button would post into the void. So the
  same value is threaded into the templates (`render.url_prefix`), which prepend it. Pinned by
  `tests/test_url_prefix.py`, including "every URL the page emits starts with the prefix".
- The session cookie's `Path` is the prefix too, so two apps on one host cannot overwrite each
  other's `dsq_sid`. Verified: `Set-Cookie: dsq_sid=…; HttpOnly; Path=/bridge-system-quiz; SameSite=lax`.

`DSQUIZ_PREFIX` accepts `bridge-system-quiz`, `/bridge-system-quiz`, or either with a trailing slash.
`just serve-deployed` runs the app locally in exactly this shape (prefix, no dev group, uvicorn,
`DSQUIZ_DEBUG=0`) — rehearse there before touching the box.

### Env flags worth setting deliberately

| flag | default | production note |
|---|---|---|
| `DSQUIZ_PREFIX` | *(root)* | `bridge-system-quiz` for the takeover; unset only for the own-host shape |
| `BML_TOOLS_DIRECTORY` | `~/dev/bml` | **must be set** — the deploy tree keeps the bml tools in `bml/` beside the corpus, so `/usr/jails/sandbox/quiz-ds/bml` |
| `DSQUIZ_TIMER` | `client` | keep it. `stream` holds a connection per tab and does per-tick server work for no scoring benefit |
| `DSQUIZ_MORPH` | `fat` | keep it |
| `DSQUIZ_OTEL` | off | needs the `telemetry` extra and a collector |
| `DSQUIZ_DEBUG` | unset | **set it to `0`.** Unset means `?debug` on the URL arms the debug panel for that session, and the panel can hand itself points, change the points goal and jump to the finale. `0` forbids it; `1` arms it for everyone (`just dev`). |

---

## 4. Making it the default quiz, step by step

### 4.1 Push the files — `just dsquiz deploy`

```shell
just dsquiz deploy              # -> DSQUIZ_DEPLOY_DIR, else X:/quiz-ds/ (samba mount of the box)
just dsquiz deploy D:/somewhere # or an explicit destination, e.g. to rehearse locally
```

It copies the **repo layout**, not a flat directory like the panel app's `just deploy-quiz`:

**Paths, and the jail.** `X:` is a samba mount of `/usr/jails/sandbox`, so one directory has three
names:

| from | path |
|---|---|
| this windows machine | `X:/quiz-ds/` |
| the host | `/usr/jails/sandbox/quiz-ds` |
| inside the jail | `/quiz-ds` |

**Use the host names.** The jail is storage here, not where anything runs: it contains no python, no
uv, no nginx and no supervisord, and the deployed panel app proves the arrangement — the shebang in
`/quiz-u16/.venv/bin/panel` reads `#!/usr/jails/sandbox/quiz-u16/.venv/bin/python`, a host path, and
its `pyvenv.cfg` points at the host's `/usr/local/bin` python 3.14.6. The venv was built, and the app
is run, from outside. Do the same for this one and there is nothing new to install anywhere.

```
X:/quiz-ds/                        (= /usr/jails/sandbox/quiz-ds from the host)
  *.bml                            the corpus -- quiz.bml_docs_dir() looks two levels up from apps/quiz
  bml/*.py                         the bml tools -- BML_TOOLS_DIRECTORY points here
  apps/quiz/                       *.py, *_topics.toml, completed.jpeg
  apps/datastar-quiz/              *.py, static/, templates/, pyproject.toml, uv.lock
```

Flattening is not an option here, and all three reasons are load-bearing: `corpus.py` puts
`../quiz` on `sys.path`, the `/media` static router serves `../quiz/completed.jpeg` from that same
directory, and the corpus is found relative to `apps/quiz/quiz.py`. `static/` and `templates/` are
deleted and recopied so a renamed asset cannot survive on the box as a stale file that still
resolves.

Not copied: `tests/`, `tools/`, `.venv/`, the markdown. `tools/measure.py` runs from *this* machine
against the deployed URL (section 6), so it does not need to be there.

### 4.2 Install on the box

As the **`apps`** user, with the same cache the panel deployment uses — the venv and its cache must
belong to the account supervisord runs as, or the first start fails on a `.venv` it cannot read:

```shell
ssh sublime.is
cd /usr/jails/sandbox/quiz-ds/apps/datastar-quiz     # host path: uv and python live out here
sudo -H -u apps uv sync --frozen --no-dev --cache-dir /home/apps/.cache/uv
```

**`-H` is load-bearing.** Without it `sudo`/`su -m` keeps the *invoking* user's `HOME`, so uv resolves
`~/.cache/uv` to the wrong tree and anything it does touch under `/home/apps` lands with the wrong
owner. The symptom is a permission error deep in the shared cache:

```
error: Failed to initialize cache at `/home/apps/.cache/uv`
  Caused by: failed to open file `/home/apps/.cache/uv/sdists-v9/.git`: Permission denied
```

If that persists even under `sudo -H -u apps`, the cache already has foreign-owned entries from an
earlier root-run `uv` — `chown -R apps:apps /home/apps/.cache/uv`. Worth checking regardless, because
that same cache is what the panel deployment's next `uv sync` will use.

**Sync here, deliberately, so the program block never syncs.** Three supervisord processes starting
at once would otherwise race to create the same `.venv` — the reason the panel block runs
`--frozen --no-sync`, and the same reason this one does. `--frozen` also means the box installs
exactly `uv.lock` and never silently re-resolves it.

No `--extra`: **uvicorn is a plain dependency, granian is the extra**, which is backwards from how
they are used locally and is entirely about this box. granian's published wheels are macos /
manylinux / musllinux / win_amd64 (grep `granian-` in `uv.lock` and there is no `freebsd` tag), so
naming it a dependency would make every `uv sync` here compile it from the sdist with a rust
toolchain. uvicorn is pure python and is what `litestar run` drives. `--no-dev` skips
pytest/ruff/ty/watchfiles. (A linux or windows host would add `--extra granian` and run
`granian --interface asgi app:app` instead of the litestar CLI below; on this box that means a source
build — see "Trying granian on the box" further down.)

`requires-python = "==3.14.*"` is satisfied by the box's **own** python — `/usr/local/bin/python3.14`
from pkg, which is what `/quiz-u16/.venv/pyvenv.cfg` already points at (`home = /usr/local/bin`,
`3.14.6`). uv publishes no managed python builds for FreeBSD, so there is nothing for it to download;
if `uv sync` cannot find a 3.14 the answer is `pkg install python314`, not a uv flag. The venv lands
in `/usr/jails/sandbox/quiz-ds/apps/datastar-quiz/.venv` and is **not** copied by `just deploy`; it belongs to the box.

**Project mode, not `--no-project`** — the same shape the panel deployment already uses. `deploy`
ships `pyproject.toml` + `uv.lock`, so the box installs the *locked* set and the deployed venv is
reproducible. (`apps/quiz/quiz_app.py` carries a PEP 723 header — `panel`, `watchfiles` — which is
what `uv run --no-project` would read instead, but the flattened `/quiz-u16` is a real project too:
its venv is named `bridge-bidding-apps` after the root `pyproject.toml` that `deploy-quiz` copies.
Nothing in either deployment resolves dependencies from a script header.)

#### Trying granian on the box (optional, and probably not worth it)

The box does have a rust toolchain, so the sdist build is available. Nothing below disturbs the
running service: uvicorn stays installed either way, because it is a plain dependency.

```shell
sudo -H -u apps uv sync --frozen --no-dev --extra granian --cache-dir /home/apps/.cache/uv
```

Minutes, not seconds — maturin may build from source too. The wheel is cached afterwards. Then run
it by hand on a spare port, beside the live workers, and measure it *bypassing nginx*:

```shell
sudo -H -u apps env DSQUIZ_PREFIX=bridge-system-quiz DSQUIZ_DEBUG=0 \
  BML_TOOLS_DIRECTORY=/usr/jails/sandbox/quiz-ds/bml \
  uv run --frozen --no-sync granian --interface asgi --host 0.0.0.0 --port 6014 app:app

# from a dev machine
just dsquiz measure --base http://www.sublime.is:6014/bridge-system-quiz
```

Check the **frame pacing**, not just the sizes: a different server re-opens the question of whether
SSE writes are flushed promptly. Adopting it is then one line in the program block —
`granian --interface asgi --host 0.0.0.0 --port 60%(process_num)02d app:app` in place of the litestar
CLI invocation.

**The trap: `granian --workers N` cannot replace the three processes.** Its workers share one
listening socket, so nginx sees a single backend and can do no affinity at all — precisely the
`panel serve --num-procs 3` failure in §2. Sessions are process-local, so it stays three
single-worker processes on distinct ports until §6 happens. Granian changes nothing about the
topology.

Worth being honest about the payoff: the endpoints measure 1.7-6.2ms for a squad-sized audience, and
granian's advantage is throughput under load this deployment does not have. Do it for the
measurement, not for the service.

### 4.3 supervisord

Deliberately the panel block (`[program:bridge-system-quiz]`) with four things changed. Host paths,
`user=apps`, the explicit uv cache, `--frozen --no-sync`, `stopasgroup`/`killasgroup` and the
`60%(process_num)02d` port trick are all carried across unchanged — they solve the same problems
here.

```ini
[program:bridge-quiz-ds]
; frozen + no-sync: the venv is synced by hand in 4.2, so three workers cannot race to build it
command=/usr/local/bin/uv run --cache-dir /home/apps/.cache/uv --frozen --no-sync
        litestar --app app:app run --host 0.0.0.0 --port 60%(process_num)02d

numprocs=3
; so ports via process_num are 6011, 6012, 6013
numprocs_start=11
process_name=bridge-quiz-ds-%(process_num)s

user=apps
directory=/usr/jails/sandbox/quiz-ds/apps/datastar-quiz
environment=DSQUIZ_PREFIX="bridge-system-quiz",DSQUIZ_DEBUG="0",BML_TOOLS_DIRECTORY="/usr/jails/sandbox/quiz-ds/bml",PYTHONDONTWRITEBYTECODE="1"

autostart=true
autorestart=true

; uv run is a wrapper -- without these, stopping kills uv and leaves the server holding the port
stopasgroup=true
killasgroup=true

stdout_logfile=/var/log/bridge-quiz-ds.log
redirect_stderr=true
```

What differs from the panel block, and why:

- **No `--project`.** `directory=` is the project directory, and uv discovers `pyproject.toml` from
  the cwd — exactly how the panel block finds `/quiz-u16`.
- **`--host 0.0.0.0` is required here, where panel needs no flag at all.** `panel serve` binds every
  interface by default; `litestar run` defaults to `127.0.0.1`, which is not how nginx reaches these
  processes (the panel `upstream` dials `www.sublime.is:600x`). Leave it off and nginx gets 502 while
  a local curl says 200. Cost: 6011-6013 answer directly, as 6005-6007 already do — §3 has the
  firewalled alternative.
- **Three env entries instead of one.** `DSQUIZ_DEBUG="0"` is the one that matters (see the flag
  table); `PYTHONDONTWRITEBYTECODE` is carried over, and here it also keeps `__pycache__` out of a
  tree that `just deploy` overwrites.
- **No `--no-dev`.** With `--no-sync`, uv runs whatever 4.2 installed and does not touch the
  environment, so the flag would do nothing; `--no-dev` belongs on the `uv sync` instead.

Two things to check in your panel block while you are in there: `redirect_stderr=tru` is not a valid
boolean (supervisord wants `true`/`false` and will refuse the section), and `stdout_logfile` without
`%(process_num)s` has all three workers appending to one file — fine, but interleaved.

Start it and check the app answers on its own port before nginx is involved — **from wherever nginx
runs**, not from a shell that happens to have a shortcut to it:

```shell
supervisorctl reread; supervisorctl update; supervisorctl start 'bridge-quiz-ds-*'
curl -s -o /dev/null -w '%{http_code}\n' http://www.sublime.is:6011/bridge-system-quiz/    # 200
```

### 4.4 Park the panel app, then swap the location block

Three edits to `/usr/local/etc/nginx/nginx.conf`, all inside the `443` server except the first.

Commented as the rest of that file is, so the reasoning survives without this document.

**1. New upstream**, in `http{}` beside `panel_app` and `opc_app`:

```nginx
    # datastar/litestar bidding quiz -- 3 processes under supervisord [program:bridge-quiz-ds],
    # ports via numprocs_start=11 and --port 60%(process_num)02d
    upstream ds_quiz {
        # (round-robin) sessions are process-local, so a player must keep hitting the same worker.
        # Keyed on the app's OWN cookie rather than ip_hash: survives a client IP change (mobile,
        # VPN) and does not collapse a whole NAT onto one worker. The very first request has no
        # cookie and hashes on the empty string -- fine, that is the request that creates it.
        # 'consistent' = ketama, so adding/removing a backend rehashes ~1/N of sessions, not all.
        hash $cookie_dsq_sid consistent;   # requires nginx >= 1.7.2
        server www.sublime.is:6011;
        server www.sublime.is:6012;
        server www.sublime.is:6013;
    }
```

**2. Park panel** by copying its existing location to a new path, body unchanged:

```nginx
        # Panel bidding quiz, PARKED. Was /bridge-system-quiz/ until the datastar port took that URL.
        # Body is unchanged from when it served the public path: the trailing slash on proxy_pass
        # strips the prefix, so panel is mounted at its own root and never learns which path reached
        # it -- which is why moving it needed no --prefix and no supervisord change.
        # ROLLBACK: put this body back under /bridge-system-quiz/ and reload.
        location ^~ /bridge-system-quiz-panel/ {
            proxy_pass http://panel_app/;      # trailing slash: strip the prefix (see above)

            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";   # bokeh needs a real websocket
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
```

`/bridge-system-quiz-panel/` does not collide with `/bridge-system-quiz/` — the character after
`quiz` is `-`, not `/`.

**3. Replace the old `/bridge-system-quiz/` body** with the datastar one:

```nginx
        # Bidding quiz (datastar/litestar). Replaced the panel app here; panel parked below.
        #
        # UNLIKE every other location in this file, proxy_pass has NO trailing slash: the app is
        # launched with DSQUIZ_PREFIX=bridge-system-quiz and prefixes its own routes AND every URL
        # it emits, so it expects the prefix to arrive intact. Adding a slash strips it and the app
        # 404s everything. (Panel is the opposite: no --prefix, mounted at root, prefix stripped.)
        location ^~ /bridge-system-quiz/ {
            proxy_pass http://ds_quiz;

            proxy_http_version 1.1;

            # (upgrade, from the panel blocks) NOT a websocket -- plain HTTP + server-sent events.
            # An empty Connection also lets upstream keepalive work.
            proxy_set_header Connection "";

            # These four repeat the server level ON PURPOSE: proxy_set_header inherits from the
            # enclosing block only when the current block declares NONE of its own. The line above
            # would otherwise silently drop Host and X-Real-IP.
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;   # not set at server level; app builds https urls from it

            # (on) REQUIRED. The answer stream is deliberately paced with server-side sleeps
            # (toast, pause, toast, pause, then the next question). Buffered, nginx holds the frames
            # and the player sees nothing for ~3s and then everything at once.
            proxy_buffering off;
            proxy_cache off;

            # (9s from http{}) that is the max gap between two writes TO THE CLIENT, which is far
            # too short for a held stream. proxy_read_timeout 900 is inherited from the server.
            send_timeout 900s;

            # NB: no gzip here on purpose -- the app brotli-compresses its own responses, including
            # the SSE streams, and nginx passes that through untouched.
        }
```

Then `nginx -t && service nginx reload`, and run §7.

Deliberately **not** folded into this change, because it is orthogonal and touches the panel and
`/opc/` blocks: both hardcode `proxy_set_header Connection "upgrade"`, which sends
`Connection: upgrade` on ordinary requests too, with an empty `Upgrade`. Tornado tolerates it; it
still defeats upstream keepalive. The fix is a `map $http_upgrade $connection_upgrade { default
upgrade; '' close; }` in `http{}` and `$connection_upgrade` in place of the literal in both.

**Rollback** is one edit: put `proxy_pass http://panel_app/;` and the websocket pair back in the
`/bridge-system-quiz/` block, reload. The datastar processes can keep running throughout.

### 4.5 Redeploying later

`just dsquiz deploy`, then on the box `sudo -H -u apps uv sync --frozen --no-dev --cache-dir
/home/apps/.cache/uv` (only if `uv.lock` moved; the program block will not sync for you) and
`supervisorctl restart 'bridge-quiz-ds-*'`. That restart **drops every in-flight quiz** (section 5),
so do it between squad sessions, not during one.

`just deploy` overwrites `pyproject.toml`/`uv.lock` and every module in place while the old processes
are still running off them — harmless, because python read them at import time, but it does mean the
window between copy and restart is running the *previous* code against the *new* files on disk. Keep
it short.

---

## 5. What survives what

| event | panel | datastar |
|---|---|---|
| browser reload | **quiz lost** | resumes exactly (page is a projection of the session) |
| second tab | new session | same session |
| connection drop | page goes inert until reload | nothing to drop; next click just works |
| app process restart | quiz lost, page inert until reload | quiz lost, next click starts a fresh one |
| one backend dies (affinity rehash) | quiz lost | quiz lost |
| browser closed | quiz lost | quiz lost — the cookie has no `Max-Age`, so it is a session cookie |
| 6h idle | n/a | session swept (`SESSION_TTL_SECONDS`) |

Neither app survives a restart, and that includes a deploy. Roll out between sessions, not during a
squad practice.

---

## 6. How to stop needing affinity at all

Only the datastar app can take this path, because its state is a plain `msgspec.Struct` rather than a
live Document with callbacks attached.

Move sessions out of the process — Redis, or sqlite on a single box — and then:

- the `hash $cookie_dsq_sid consistent;` line becomes unnecessary; any worker can serve any request;
- restarts and deploys stop losing quizzes;
- the three supervisord processes collapse into one multi-worker server (`uvicorn --workers 3`).

What has to happen in the code, roughly 60-100 lines:

1. **Do not persist `sequences`** — it is a slice of the per-process bml corpus. Persist
   `variant.key` + `filter_text` and re-derive it on load, exactly as `Session.apply_filter` already
   does.
2. **Persist the current `question`** rather than re-drawing it, or the question changes under the
   player on a failover.
3. **Not a signed cookie.** Litestar's cookie sessions are signed, not encrypted, so
   `question.answer_candidate` would ship to the browser — the one thing `state.py` exists to prevent.

---

## 7. Verifying a deployment

**Use `-D-`, not `-I`.** `curl -I` sends a HEAD, and the app answers HEAD with **405** — a check
written that way fails on a perfectly good deployment.

```shell
B=https://sublime.is/bridge-system-quiz

# the page is served and carries its own session cookie, scoped to the prefix
curl -s -D- -o /dev/null $B/ | grep -i 'set-cookie\|^HTTP'
#   expect: 200, and dsq_sid=...; HttpOnly; Path=/bridge-system-quiz; SameSite=lax

# affinity. Add `add_header X-Upstream $upstream_addr always;` at SERVER level, beside the HSTS
# header -- NOT inside the location, where declaring any add_header drops the inherited HSTS.
# (Or put $upstream_addr in log_format main and read the access log instead; worth keeping.)
#
# (a) one session pins to one worker:
rm -f /tmp/cj; curl -s -c /tmp/cj -o /dev/null $B/
for i in 1 2 3 4 5; do curl -s -b /tmp/cj -D- -o /dev/null $B/ | grep -i x-upstream; done
#
# (b) and the hash is not degenerate -- distinct sessions spread over the three workers. Without
# this, a cookie that never reaches the hash looks identical to working affinity: everything pins,
# all of it to one worker. A cookie-less request always lands on the same worker (the empty string
# hashes to a constant); that is by design, not a fault.
for i in 1 2 3 4 5 6; do
    rm -f /tmp/cj$i
    curl -s -c /tmp/cj$i -o /dev/null $B/
    curl -s -b /tmp/cj$i -D- -o /dev/null $B/ | grep -i x-upstream
done

# every emitted URL must carry the prefix (this is the failure that looks like "no CSS")
curl -s $B/ | grep -o 'href="[^"]*"\|src="[^"]*"' | sort -u
curl -s $B/ | grep -o "@post('[^']*'" | sort -u

# the assets the two static routers serve, one of which comes from apps/quiz -- 200 each.
# `pico.classless.min.css` is in the list because it is NOT emitted by a template: the adapter sheet
# `@import`s it, so it is the one URL the prefix cannot be pasted into. Rooted at `/static/...` it
# 404d here and nowhere else, and the symptom was a WHITE quiz card in dark mode -- with Pico's
# tokens missing, `.card` fell through to its `#fff` fallback while the rest of the page, painted
# from the adapter's own tokens, stayed dark. It is a relative import now; this line is the check.
for p in /static/app-pico.css /static/pico.classless.min.css /static/datastar.js /media/completed.jpeg; do
    printf '%s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' $B$p)"
done

# a real round trip: cookie, then an answer, and SSE frames come back
curl -s -c /tmp/cj -o /dev/null $B/
curl -s -b /tmp/cj -X POST $B/answer/1/0 -H 'Accept: text/event-stream' | head -c 400

# SSE is not being buffered: frames should arrive spread over ~2-3s, not all at the end
just dsquiz measure --base $B
```

`tools/measure.py` prints chunk arrival times and says "paced" or "BUNCHED: buffered?" — the second
means `proxy_buffering off` is missing or a cache is in the way.

Also worth checking after any nginx change: `nginx -t`, then that the panel quiz's websocket still
connects (browser devtools → Network → WS, status 101).

---

## 8. Things this config does not do

- **No health checks.** Open-source nginx marks a backend down only after a failed request. A hung-but-
  listening worker keeps receiving traffic.
- **No graceful drain on deploy.** Restarting a backend drops its sessions immediately.
- **No rate limiting on the app locations.** `limit_conn addr` is applied to the static server only;
  the quiz endpoints are cheap (1.7-6.2ms) but unbounded.
- **`proxy_intercept_errors on`** is set with no `error_page` for 5xx in the 443 server, so a backend
  restart shows nginx's default error page rather than anything friendly.

None of these are urgent for a squad-sized audience; they are the list to work through if it ever
matters more than that.
