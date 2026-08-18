"""Pulling one thing out of rendered markup, without the `Optional[Match]` dance.

`re.search(...).group(1)` is the natural line to write in these tests and it is also a type error:
`search` returns `Match | None`, so every call site either grows a two-line assert or fails
`ty check`. The assert is the right behaviour -- a pattern that does not match means the markup
changed, and the test should say so -- but it is the same three lines every time, and half the call
sites had drifted into the untyped shorthand.

So: one helper that asserts and returns a `Match`, which is what the tests were assuming anyway. It
fails with the pattern in the message, which is more than `AttributeError: 'NoneType'` ever said.
"""

from __future__ import annotations

import re


def found(pattern: str, text: str, flags: int = 0) -> re.Match[str]:
    """`re.search`, but a miss is a test failure rather than a `None` to unwrap."""
    match = re.search(pattern, text, flags)
    assert match is not None, f"nothing in the rendered markup matched {pattern!r}"
    return match
