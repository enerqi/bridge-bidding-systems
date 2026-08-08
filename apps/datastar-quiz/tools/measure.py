"""Measure payload sizes and SSE frame pacing against a running server.

    uv run --project . python tools/measure.py [--base http://127.0.0.1:5008]

Reports, for the current server's DSQUIZ_MORPH mode:
  * the document and one interaction, raw vs brotli
  * whether compression delays the SSE toast sequence (it must not: the frames are paced by the
    server's own sleeps, so their arrival times should be ~0.6s apart, not bunched at the end)

Kept in the repo because these are the numbers COMPARISON.md quotes, and they should be
re-measurable rather than folklore.
"""

from __future__ import annotations

import argparse
import time
from typing import Any

import httpx

DS = {"Datastar-Request": "true", "Content-Type": "application/json"}


def sizes(client: httpx.Client, method: str, path: str, **kw: Any) -> tuple[int, int]:
    """(raw bytes, brotli bytes) for one response."""
    plain = client.request(method, path, headers={**DS, "Accept-Encoding": "identity"}, **kw)
    raw = len(plain.content)
    with client.stream(method, path, headers={**DS, "Accept-Encoding": "br"}, **kw) as response:
        for _ in response.iter_raw():
            pass
        encoded = response.num_bytes_downloaded
        encoding = response.headers.get("content-encoding", "none")
    return raw, encoded if encoding != "none" else raw


def report(label: str, raw: int, encoded: int) -> None:
    ratio = f"{raw / encoded:.1f}x" if encoded else "-"
    print(f"  {label:<34} raw {raw:>7,}  br {encoded:>6,}  {ratio:>6} smaller")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:5008")
    args = parser.parse_args()

    with httpx.Client(base_url=args.base, timeout=30.0) as client:
        client.get("/")  # establish the session cookie

        print("payload sizes")
        report("GET / (document)", *sizes(client, "GET", "/"))
        report("POST /skip (one interaction)", *sizes(client, "POST", "/skip", content="{}"))
        # every variant of the CSS A/B/C, plus the frameworks they import: the adapter is the part
        # we maintain, the vendored file is the part the visitor downloads, and the comparison is
        # only honest with both
        for sheet in (
            "app.css",
            "app-pico.css",
            "pico.classless.min.css",
            "app-bulma.css",
            "bulma.min.css",
        ):
            report(f"GET /static/{sheet}", *sizes(client, "GET", f"/static/{sheet}"))
        report("GET /static/datastar.js", *sizes(client, "GET", "/static/datastar.js"))

        # frame pacing: a wrong answer shows toasts with server-side sleeps between them
        print("\nSSE frame arrival, compressed (a wrong answer's toast sequence)")
        page = client.get("/").text
        qid = page.split("/answer/")[1].split("/")[0]
        start = time.perf_counter()
        with client.stream(
            "POST",
            f"/answer/{qid}/0",
            headers={**DS, "Accept-Encoding": "br"},
            content="{}",
        ) as response:
            print(f"  content-encoding: {response.headers.get('content-encoding', 'none')}")
            arrivals = [round((time.perf_counter() - start) * 1000) for chunk in response.iter_raw() if chunk]
        print(f"  chunk arrivals (ms): {arrivals}")
        if len(arrivals) > 1:
            spread = arrivals[-1] - arrivals[0]
            print(f"  spread {spread} ms over {len(arrivals)} chunks", end="")
            print(" -- paced, so compression is not buffering" if spread > 300 else " -- BUNCHED: buffered?")


if __name__ == "__main__":
    main()
