"""Glob-based path matching against include/exclude rules.

Patterns are gitignore-style, matched against repo-relative POSIX paths:

- ``**`` spans **one or more whole segments** — ``app/**`` matches
  ``app/features`` but not ``app`` itself; a leading or trailing ``**``
  likewise needs a segment on that side.
- ``*`` and ``?`` stay within one segment (they never match ``/``).
- Everything else in a segment is literal. Character classes are not
  supported; the configs this ships with only use literals and ``*``.

The reference semantics were ``pathlib.PurePosixPath.full_match``, which is
Python 3.13+; this hand-rolled translation keeps the tracker running on any
Python >= 3.11 while preserving the behaviour the test suite pins.
"""

from __future__ import annotations

import re
from functools import lru_cache

from .config import TargetRule


@lru_cache(maxsize=None)
def _pattern_regex(pattern: str) -> re.Pattern[str]:
    segments = pattern.split("/")
    parts: list[str] = []
    for segment in segments:
        if segment == "**":
            # One or more whole segments — never zero.
            parts.append(r"[^/]+(?:/[^/]+)*")
            continue
        piece: list[str] = []
        for char in segment:
            if char == "*":
                piece.append("[^/]*")
            elif char == "?":
                piece.append("[^/]")
            else:
                piece.append(re.escape(char))
        parts.append("".join(piece))
    return re.compile("/".join(parts))


def _matches_any(path: str, patterns: list[str]) -> bool:
    return any(_pattern_regex(pattern).fullmatch(path) for pattern in patterns)


def matches_rule(path: str, rule: TargetRule) -> bool:
    """True iff ``path`` matches the rule's includes and not its excludes."""
    if not _matches_any(path, rule.include):
        return False
    return not (rule.exclude and _matches_any(path, rule.exclude))
