# Deploying the quiz apps behind nginx

Written against the live `sublime.is` config (FreeBSD, nginx + supervisord, TLS from letsencrypt).
Covers the **panel** quiz that is already deployed and the **datastar** quiz that is taking over its
URL, because the two need different things from the proxy and the differences are the interesting
part.

**Status: the datastar half has not yet run on the box.** Everything below was rehearsed locally
against a real `just deploy` tree — the deployed layout, `uv sync --no-dev`, the
prefix, the cookie `Path`, brotli, `/media/completed.jpeg` and a full answer round trip all check out
under uvicorn (section 6 is the same checks against the box). What is untested is nginx and
supervisord in front of it.

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

### nginx

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

---

## 3. The datastar app

It needs **less** than panel (no websocket) and one thing more (SSE must not be buffered). It can
also do affinity properly, because it has its own cookie.

### The plan: take over `/bridge-system-quiz/`

```nginx
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

`^~` beats the panel's regex locations if any exist; with two prefix locations, the longest match
wins, so a `/bridge-system-quiz/` block and a `/bridge-system-quiz-panel/` block coexist happily
while the panel app is parked.

### Alternative — its own host (zero prefix work)

Worth knowing about, because it is the shape with the fewest moving parts if the panel app is ever
retired rather than parked: point a hostname at the same upstream, mount at the root, drop
`DSQUIZ_PREFIX` entirely. Needs DNS and a name on the certificate.

```nginx
upstream ds_quiz {
    hash $cookie_dsq_sid consistent;   # cookie affinity, nginx OSS (>=1.7.2)
    server www.sublime.is:6011;
    server www.sublime.is:6012;
    server www.sublime.is:6013;
}

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
| `BML_TOOLS_DIRECTORY` | `~/dev/bml` | **must be set** — the deploy tree keeps the bml tools in `bml/` beside the corpus, so `/quiz-ds/bml` |
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

```
X:/quiz-ds/                        (= /quiz-ds on the box)
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

```shell
ssh sublime.is
cd /quiz-ds/apps/datastar-quiz
uv sync --no-dev
```

No `--extra`: **uvicorn is a plain dependency, granian is the extra**, which is backwards from how
they are used locally and is entirely about this box. granian's published wheels are macos /
manylinux / musllinux / win_amd64 (grep `granian-` in `uv.lock` and there is no `freebsd` tag), so
naming it a dependency would make every `uv sync` here compile it from the sdist with a rust
toolchain. uvicorn is pure python and is what `litestar run` drives. `--no-dev` skips
pytest/ruff/ty/watchfiles. (A linux or windows host would add `--extra granian` and run
`granian --interface asgi app:app` instead of the litestar CLI below.)

`requires-python = "==3.14.*"` is satisfied by the box's **own** python — `/usr/local/bin/python3.14`
from pkg, which is what `/quiz-u16/.venv/pyvenv.cfg` already points at (`home = /usr/local/bin`,
`3.14.6`). uv publishes no managed python builds for FreeBSD, so there is nothing for it to download;
if `uv sync` cannot find a 3.14 the answer is `pkg install python314`, not a uv flag. The venv lands
in `/quiz-ds/apps/datastar-quiz/.venv` and is **not** copied by `just deploy`; it belongs to the box.

**Project mode, not `--no-project`** — the same shape the panel deployment already uses. `deploy`
ships `pyproject.toml` + `uv.lock`, so the box installs the *locked* set and the deployed venv is
reproducible. (`apps/quiz/quiz_app.py` carries a PEP 723 header — `panel`, `watchfiles` — which is
what `uv run --no-project` would read instead, but the flattened `/quiz-u16` is a real project too:
its venv is named `bridge-bidding-apps` after the root `pyproject.toml` that `deploy-quiz` copies.
Nothing in either deployment resolves dependencies from a script header.)

### 4.3 supervisord

```ini
[program:bridge-quiz-ds]
command=/usr/local/bin/uv run --project /quiz-ds/apps/datastar-quiz --no-dev
        litestar --app app:app run --host 127.0.0.1 --port %(process_num)s
process_name=%(program_name)s_%(process_num)s
numprocs=3
numprocs_start=6011
directory=/quiz-ds/apps/datastar-quiz
environment=DSQUIZ_PREFIX="bridge-system-quiz",DSQUIZ_DEBUG="0",BML_TOOLS_DIRECTORY="/quiz-ds/bml"
autostart=true
autorestart=true
user=www
stdout_logfile=/var/log/ds-quiz-%(process_num)s.log
redirect_stderr=true
```

`DSQUIZ_DEBUG="0"` is the one entry that is a real decision rather than plumbing — see the flag table
above. `www` must be able to read `/quiz-ds` and write `.venv` there (or run `uv sync` as `www`).

Start it and check the app answers on its own port before nginx is involved:

```shell
supervisorctl reread; supervisorctl update; supervisorctl start bridge-quiz-ds:*
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:6011/bridge-system-quiz/    # 200
```

### 4.4 Park the panel app, then swap the location block

Order matters only in that both must not claim `/bridge-system-quiz/` at once:

1. Point the existing panel `location` at a new path — `/bridge-system-quiz-panel/` — and relaunch
   panel with `--prefix bridge-system-quiz-panel` to match. Or stop it, if nobody needs the fallback.
2. Replace the `/bridge-system-quiz/` block with the datastar one from section 3, add the `ds_quiz`
   upstream, and delete the `Upgrade`/`Connection` websocket pair from it.
3. `nginx -t && service nginx reload`.
4. Run the checks in section 6.

**Rollback is step 1 in reverse** — put the old `location` body back and reload. The datastar
processes can keep running on 6011-6013 the whole time; nothing about them is bound to the URL except
`DSQUIZ_PREFIX`.

### 4.5 Redeploying later

`just dsquiz deploy`, then on the box `uv sync --no-dev` (only if the lock moved) and
`supervisorctl restart bridge-quiz-ds:*`. That restart **drops every in-flight quiz** (section 5), so
do it between squad sessions, not during one.

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

# affinity: add `add_header X-Upstream $upstream_addr always;` to the location temporarily,
# then confirm it stays constant across requests from one client
curl -s -D- -o /dev/null $B/ | grep -i x-upstream

# every emitted URL must carry the prefix (this is the failure that looks like "no CSS")
curl -s $B/ | grep -o 'href="[^"]*"\|src="[^"]*"' | sort -u
curl -s $B/ | grep -o "@post('[^']*'" | sort -u

# the assets the two static routers serve, one of which comes from apps/quiz -- 200 each
for p in /static/app.css /static/datastar.js /media/completed.jpeg; do
    printf '%s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' $B$p)"
done

# a real round trip: cookie, then an answer, and SSE frames come back
curl -s -c /tmp/cj -o /dev/null $B/
curl -s -b /tmp/cj -X POST $B/answer/1/0 -H 'Accept: text/event-stream' | head -c 400

# SSE is not being buffered: frames should arrive spread over ~2-3s, not all at the end
uv run --project apps/datastar-quiz python tools/measure.py --base $B
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
