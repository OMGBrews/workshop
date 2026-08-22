"""Glob-based path matching against include/exclude rules.

Patterns are gitignore-style, matched against repo-relative POSIX paths:

- ``**`` matches whole segments. A ``**`` at the start or between two other
  segments may match **zero** of them (``app/**/*.py`` matches ``app/x.py``;
  ``**/__pycache__/**`` matches ``__pycache__/x.py``). A ``**`` at the end
  requires at least one segment on its side (``app/**`` matches ``app/x`` but
  not ``app`` itself).
- ``*`` and ``?`` stay within one segment (they never match ``/``).
- Everything else in a segment is literal. Character classes are not
  supported; the configs this ships with only use literals and ``*``.

The reference semantics were measured against ``pathlib.PurePosixPath
.full_match`` on CPython 3.13, which the tracker previously required; this
hand-rolled translation keeps it running on any Python >= 3.11 while
preserving the behaviour the test suite pins.
"""

from __future__ import annotations

import re
from functools import lru_cache

from .config import TargetRule


@lru_cache(maxsize=None)
def _pattern_regex(pattern: str) -> re.Pattern[str]:
    def segment_rx(segment: str) -> str:
        piece: list[str] = []
        for char in segment:
            if char == "*":
                piece.append("[^/]*")
            elif char == "?":
                piece.append("[^/]")
            else:
                piece.append(re.escape(char))
        return "".join(piece)

    segments = pattern.split("/")
    tokens: list[str] = []
    last = len(segments) - 1
    for i, segment in enumerate(segments):
        if segment == "**":
            if i == last:
                # Trailing **: one or more whole segments.
                tokens.append("[^/]+(?:/[^/]+)*")
            else:
                # Leading or interior **: zero or more whole segments,
                # slashes included, so the next segment glues directly on.
                tokens.append("(?:[^/]+/)*")
        elif i == last:
            tokens.append(segment_rx(segment))
        else:
            tokens.append(segment_rx(segment) + "/")
    return re.compile("".join(tokens))



def _matches_any(path: str, patterns: list[str]) -> bool:
    return any(_pattern_regex(pattern).fullmatch(path) for pattern in patterns)


def matches_rule(path: str, rule: TargetRule) -> bool:
    """True iff ``path`` matches the rule's includes and not its excludes."""
    if not _matches_any(path, rule.include):
        return False
    return not (rule.exclude and _matches_any(path, rule.exclude))
