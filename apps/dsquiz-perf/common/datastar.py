"""The datastar wire protocol, as this app speaks it, plus the request helpers every scenario uses.

Three things a simulated browser has to get right, and all three are why this file exists rather
than raw `self.client.post(...)` calls in the scenarios:

* **Signals go up with every request.** Datastar uploads the browser-owned signals (`difficulty`,
  `ladderMode`, `targetOn`, `targetPct`, `filterText`, `topics`) as a JSON body on a POST and as a
  `?datastar=<json>` query parameter on a GET. `app._sync_settings` adopts them, so a user whose
  profile says difficulty 8 must actually say so on every call or the server keeps its own value.
* **The response is SSE, not HTML.** Element patches and signal patches arrive as
  `event: datastar-patch-elements` frames. The next question's id is inside one of them, so the
  scenarios drive the quiz by reading the reply, exactly as a browser does.
* **The session is a cookie.** `FastHttpUser` gives every user its own `CookieJar`, so N locust
  users are N independent server-side sessions with no work on our part -- see the README.
"""

from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from typing import TYPE_CHECKING
from urllib.parse import quote

from common import config

if TYPE_CHECKING:
    from locust.contrib.fasthttp import FastHttpUser

DS_HEADERS = {
    # what the datastar client sends; the SDK's `read_signals` does not require it, but the app is
    # entitled to look at it and a load test that lies about being a browser is not a load test
    "Datastar-Request": "true",
    "Accept": "text/event-stream",
    "Content-Type": "application/json",
    "Accept-Encoding": config.ACCEPT_ENCODING,
}

PAGE_HEADERS = {
    "Accept": "text/html,application/xhtml+xml",
    "Accept-Encoding": config.ACCEPT_ENCODING,
}

# `@post('/answer/12/3?swedish')` -- the click handler, one per candidate button. The keyboard
# handler builds its URL by concatenation and is deliberately not matched: it would report the
# wrong index, and there is no second question hiding in it.
_ANSWER_RE = re.compile(r"/answer/(\d+)/(\d+)(\?[^'\"]*)?")
# any action URL, which is where the mount prefix and the variant query can be read off the page
_ACTION_RE = re.compile(r"@post\('([^']*?)/(?:answer/\d+/\d+|next|skip|restart)(\?[^']*)?'\)")
_NEXT_RE = re.compile(r"@post\('[^']*?/next(?:\?[^']*)?'\)")
_TOPIC_RE = re.compile(r"data-bind:topics\.([\w-]+)")
_ASSET_RE = re.compile(r"""(?:href|src)=["']([^"']*/static/[^"'?]+)["']""")
# server-owned signals arrive as JSON in an SSE frame, but on the full page they sit inside an
# attribute (`<body data-signals="...">`) where jinja has escaped every quote
_QUOTE = r"""(?:&\#34;|&quot;|["'])"""

# A datastar response with NO events is a 204, and this app returns one deliberately whenever a press
# no longer applies: Skip with none left, Next while not on a reveal, a settings POST that changed
# nothing, an answer to a finished quiz, `/timer` in the default client mode. That is a correct answer
# to a stale click, not a server error -- the Confluence guide's "Failure Definition" section is about
# exactly this, and treating 204 as a failure is what made `/timer` read as 100% failed.
NO_OP = 204
SUCCESS_CODES = (200, NO_OP)


def _signal(body: str, name: str) -> str | None:
    match = re.search(rf"{name}{_QUOTE}?\s*:\s*([-\w.]+)", body)
    return match.group(1) if match else None


@dataclass
class View:
    """What the page is currently showing, read back out of the HTML or the SSE reply.

    `qid` is the question nonce. Answering with a stale one is not scored -- the server resyncs the
    page instead (`app._stale`) -- so a scenario that guesses or reuses it measures the resync path
    and nothing else.
    """

    qid: int | None = None
    candidates: int = 0
    awaiting_next: bool = False
    completed: bool = False
    playing: bool = True
    skips_left: int = 0
    prefix: str | None = None
    variant_query: str = ""
    topic_slugs: tuple[str, ...] = ()
    assets: tuple[str, ...] = ()
    raw_len: int = 0

    def can_answer(self) -> bool:
        return self.playing and not self.awaiting_next and self.qid is not None and self.candidates > 0


def parse_view(body: str, previous: View | None = None) -> View:
    """Read a page or an SSE reply into a `View`.

    Both are parsed the same way on purpose: a fat-morph patch carries the whole `#app` body, so the
    markers are identical whether they arrived in the document or in an element patch. Anything the
    reply does not mention is inherited from `previous` -- a skip patches the quiz body only, and
    forgetting the prefix at that point would send the next request to the wrong URL.
    """
    view = View(raw_len=len(body))
    old = previous or View()

    answers = _ANSWER_RE.findall(body)
    if answers:
        view.qid = int(answers[0][0])
        view.candidates = max(int(index) for _, index, _ in answers) + 1
        view.variant_query = answers[0][2] or ""
    else:
        view.variant_query = old.variant_query

    action = _ACTION_RE.search(body)
    view.prefix = action.group(1) if action else old.prefix
    if action and action.group(2):
        view.variant_query = action.group(2)

    view.awaiting_next = bool(_NEXT_RE.search(body))
    view.completed = 'class="finale"' in body or "Quiz complete" in body

    playing = _signal(body, "_playing")
    view.playing = old.playing if playing is None else playing == "true"
    if view.completed:
        view.playing = False

    skips = _signal(body, "_skipsLeft")
    view.skips_left = old.skips_left if skips is None else int(skips)

    view.topic_slugs = tuple(dict.fromkeys(_TOPIC_RE.findall(body))) or old.topic_slugs
    view.assets = tuple(dict.fromkeys(_ASSET_RE.findall(body))) or old.assets
    return view


# --- the topic signal names -------------------------------------------------
#
# A ticked topic is a signal named after its slug, and the name is not the slug: datastar converts
# kebab attribute keys to camel signals, splitting letter/digit boundaries on the way, so
# `topics.1c-opening` is the signal `topics.1COpening`. These mirror `render.datastar_kebab` /
# `datastar_camel` in the app -- duplicated rather than imported so this project never has to
# install litestar to send a request to it.


def _kebab(text: str) -> str:
    out = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1-\2", text)
    out = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", out)
    out = re.sub(r"([a-z])([0-9]+)", r"\1-\2", out, flags=re.IGNORECASE)
    out = re.sub(r"([0-9]+)([a-z])", r"\1-\2", out, flags=re.IGNORECASE)
    out = re.sub(r"[\s_]+", "-", out)
    return out.lower()


def topic_signal_key(slug: str) -> str:
    return re.sub(r"-(.)", lambda match: match.group(1).upper(), _kebab(slug))


# --- requests ---------------------------------------------------------------


@dataclass
class Signals:
    """The browser-owned signal set this user uploads with every request."""

    difficulty: int = 5
    ladder_mode: bool = False
    target_on: bool = False
    target_pct: int = 80
    filter_text: str = ""
    topics: dict[str, bool] = field(default_factory=dict)

    def payload(self) -> dict:
        return {
            "difficulty": self.difficulty,
            "ladderMode": self.ladder_mode,
            "targetOn": self.target_on,
            "targetPct": self.target_pct,
            "filterText": self.filter_text,
            "topics": self.topics,
        }

    def body(self) -> str:
        return json.dumps(self.payload())

    def query(self, url: str) -> str:
        """A GET carries the same signals in `?datastar=<json>` (`read_signals` reads either)."""
        separator = "&" if "?" in url else "?"
        return f"{url}{separator}datastar={quote(self.body())}"


def action_url(view: View, path: str) -> str:
    """`/skip` -> `/bridge-system-quiz/skip?swedish`, using what the page itself said."""
    return f"{prefix_of(view)}{path}{view.variant_query}"


def prefix_of(view: View) -> str:
    return view.prefix if view.prefix is not None else config.PREFIX


def load_page(user: FastHttpUser, query: str = "", *, name: str = "GET /") -> View:
    """A real navigation: the full document, and the only response that carries the shell."""
    with user.client.get(f"{config.PREFIX}/{query}", name=name, headers=PAGE_HEADERS, catch_response=True) as response:
        if response.status_code != 200:
            response.failure(f"page load returned {response.status_code}")
            return View()
        view = parse_view(response.text or "")
        # A page parked on the REVEAL carries no `/answer/...` URLs at all -- the answer is shown in
        # place and the only control is Next -- and the finale carries none either. Demanding a
        # question here failed a page that was perfectly correct.
        if view.qid is None and not (view.awaiting_next or view.completed):
            response.failure("page carried neither a question, a reveal nor the finale")
        return view


def post_action(user: FastHttpUser, view: View, path: str, signals: Signals, *, name: str | None = None) -> View:
    """One datastar POST (`/next`, `/skip`, `/restart`, `/settings`, `/filter/apply*`).

    An empty body is a valid answer here -- the server no-ops a press that no longer applies, such
    as Skip with none left -- so it is not a failure, and `previous` carries the old view through.
    """
    url = action_url(view, path)
    with user.client.post(
        url, name=name or f"POST {path}", headers=DS_HEADERS, data=signals.body(), catch_response=True
    ) as response:
        if response.status_code not in SUCCESS_CODES:
            response.failure(f"{path} returned {response.status_code}")
            return view
        return parse_view(response.text or "", previous=view)


def get_action(user: FastHttpUser, view: View, path: str, signals: Signals, *, name: str | None = None) -> View:
    """One datastar GET (`/filter/preview`, `/filter/preview-topics`, `/filter/topics-reset`)."""
    url = signals.query(action_url(view, path))
    with user.client.get(url, name=name or f"GET {path}", headers=DS_HEADERS, catch_response=True) as response:
        if response.status_code not in SUCCESS_CODES:
            response.failure(f"{path} returned {response.status_code}")
            return view
        return parse_view(response.text or "", previous=view)


def answer(user: FastHttpUser, view: View, index: int, signals: Signals) -> tuple[View, float]:
    """Answer the live question, and time the two halves of it separately.

    `stream=True` is the whole point. The handler scores the answer and *then* returns a generator,
    so the response headers leave the server once the scoring is done -- and locust stops its clock
    at the headers when streaming. `POST /answer` in the report is therefore the server's real work
    per answer, uncontaminated by the two to four seconds of `asyncio.sleep` the toast choreography
    then spends. The whole stream is timed here instead and judged against a budget
    (`common.slow_sse_stream_rate`), because a mean that is mostly deliberate sleeping tells you
    nothing, while a stream running well past its own pacing says the event loop is starved.

    Returns the new view and the whole-stream duration in milliseconds.
    """
    # the index goes between the path and the query, so `action_url` cannot build this one
    url = f"{prefix_of(view)}/answer/{view.qid}/{index}{view.variant_query}"

    started = time.perf_counter()
    with user.client.post(
        url, name="POST /answer", headers=DS_HEADERS, data=signals.body(), stream=True, catch_response=True
    ) as response:
        if response.status_code not in SUCCESS_CODES:
            response.failure(f"/answer returned {response.status_code}")
            return view, 0.0
        if response.status_code == NO_OP:
            # the quiz had already finished, or the page was behind -- nothing was scored and there is
            # no stream to time
            return view, 0.0
        body = response.text or ""  # reads (and decompresses) the whole stream, after the timing
        stream_ms = (time.perf_counter() - started) * 1000
        # locust cannot measure the length of a streamed body, so put the decoded size back. It is
        # not the wire size (that was compressed), but it is the number the fat/fragment morph
        # comparison in COMPARISON.md is about.
        response.request_meta["response_length"] = len(body)
        if not body:
            response.failure("answer stream was empty")  # a 200 with no events would be a real fault
        return parse_view(body, previous=view), stream_ms
