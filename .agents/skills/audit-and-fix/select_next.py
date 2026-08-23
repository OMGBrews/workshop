#!/usr/bin/env python3
"""Pick the next audit target for the ``audit-and-fix`` skill, and validate it.

``audit-and-fix`` could tell its caller to run the tracker and read the first
line of the output as a tab-separated selection. That is unsafe for a caller reading
a stream as it arrives: the tracker writes ``audit_tracker:`` notices
(auto-refresh, orphan records) to **stderr** as soon as it starts, while the
candidate reaches **stdout** only after the query completes. Seeing the notices
first — or seeing nothing yet — reads as "no candidates" even when the tracker
is about to name thousands.

This selector removes the ambiguity by making completion a property of the
process rather than of whoever is watching it:

1. run the tracker once, in the foreground, capturing both streams so neither
   reaches our own stdout/stderr while the child is alive;
2. check the child's exit status *before* looking at its stdout;
3. ask for the tracker's native JSON and accept only its documented
   ``selected`` / ``empty`` / ``not-configured`` shapes (with exactly one
   candidate for ``selected``);
4. print one JSON object, only once all of the above holds.

A tracker failure and unexpected output are reported by a **non-zero exit**,
never by a success-shaped record: the caller must not be able to reach
"nothing to audit" by any route except the tracker explicitly saying so.

No ``refresh`` is issued here. The tracker already auto-refreshes when its
cache is stale, and its notice about doing so is one of the stderr lines this
selector keeps out of the selection.

Stdlib-only on purpose: the skill invokes it with plain ``python3``, with no
venv guarantee — and the tracker child it spawns is stdlib-only too, via the
launcher at ``tracker.py`` beside this file.

The tracker's native JSON reports an unconfigured repo distinctly. Exit 4 is
still accepted for compatibility with an older tracker launcher.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, TypedDict

if sys.version_info < (3, 11):
    sys.exit(
        "audit-and-fix selector: Python 3.11+ is required; running "
        + sys.version.split()[0]
    )

# Exit codes. Any non-zero value means "no validated selection"; they are
# distinguished so a caller (and the tests) can tell a broken tracker from a
# tracker whose output this selector does not recognise.
# EXIT_TRACKER_NOT_CONFIGURED never leaves this process: it is interpreted
# into a success-shaped outcome below. 2 is left to argparse.
EXIT_OK = 0
EXIT_TRACKER_FAILED = 1
EXIT_MALFORMED_OUTPUT = 3
EXIT_TRACKER_NOT_CONFIGURED = 4

class SelectedResult(TypedDict):
    """A validated tracker candidate."""

    outcome: Literal["selected"]
    path: str
    kind: str
    reason: str
    diagnostics: list[str]


class NotConfiguredResult(TypedDict):
    """The repo has not opted in: no ``docs/work/audits/config.toml``."""

    outcome: Literal["not-configured"]
    diagnostics: list[str]


class EmptyResult(TypedDict):
    """The tracker said, in as many words, that it has no candidate."""

    outcome: Literal["empty"]
    diagnostics: list[str]


SelectionResult = SelectedResult | EmptyResult | NotConfiguredResult


@dataclass(frozen=True)
class TrackerRun:
    """A completed ``audit_tracker next`` invocation, streams already drained."""

    returncode: int
    stdout: str
    stderr: str


class SelectorError(Exception):
    """A run that cannot yield a validated selection.

    Carries the exit code the CLI should return, so no failure path can fall
    through to the success-shaped JSON.
    """

    def __init__(self, message: str, exit_code: int, diagnostics: list[str]) -> None:
        super().__init__(message)
        self.exit_code = exit_code
        self.diagnostics = diagnostics


def repo_root() -> Path:
    """Repository root of **this process's** working directory.

    Not this file's own location: the selector ships inside the pinned
    workshop mount, so ``__file__`` resolves into the mount while the audited
    tree is the consumer repo around it. SKILL.md mandates running from the
    consumer repo root; ``git rev-parse --show-toplevel`` reports that root —
    through worktrees and submodules too. The tracker child inherits this
    CWD and derives the same root itself.
    """
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "audit-and-fix selector: run it from inside the consumer's git "
            f"repository ({result.stderr.strip()})"
        )
    return Path(result.stdout.strip())


def build_command(audit_type: str, kind: str | None, under: str | None) -> list[str]:
    """The tracker invocation, built from the skill's own arguments.

    The launcher at ``tracker.py`` sits beside this file's *physical*
    directory — one ``resolve()`` through whatever bridge symlink the
    consumer reached in through (see workshop's skill-path-resolution doc).
    ``-n 1`` is explicit rather than inherited from the tracker's default:
    this selector rejects multi-record stdout, and stating the expectation at
    the call site keeps that rejection from turning into a false failure if
    the default ever moves.
    """
    command = [
        "python3",
        str(Path(__file__).resolve().with_name("tracker.py")),
        "next",
        audit_type,
        "-n",
        "1",
        "--format",
        "json",
    ]
    if kind is not None:
        command += ["--kind", kind]
    if under is not None:
        command += ["--under", under]
    return command


def invoke_tracker(command: list[str], cwd: Path) -> TrackerRun:
    """Run ``command`` to completion, capturing both streams.

    The foreground wait *is* the completion boundary: ``subprocess.run`` returns
    only once the child has exited and both pipes are drained, and
    ``capture_output`` keeps every byte of them out of this process's own
    streams in the meantime. Nothing a caller can read from us exists before the
    tracker is done.
    """
    completed = subprocess.run(
        command,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )
    return TrackerRun(completed.returncode, completed.stdout, completed.stderr)


def diagnostics_from(stderr: str) -> list[str]:
    """The tracker's stderr, as lines, for the result's ``diagnostics`` field."""
    return [line.rstrip() for line in stderr.splitlines() if line.strip()]


def interpret(run: TrackerRun) -> SelectionResult:
    """Validate a completed run, or raise ``SelectorError``.

    Order matters: exit status first, then the shape of stdout. A tracker that
    died after printing a plausible line must not be read as a selection.
    """
    diagnostics = diagnostics_from(run.stderr)

    if run.returncode == EXIT_TRACKER_NOT_CONFIGURED:
        return NotConfiguredResult(outcome="not-configured", diagnostics=diagnostics)
    if run.returncode != 0:
        raise SelectorError(
            f"audit_tracker exited {run.returncode}",
            EXIT_TRACKER_FAILED,
            diagnostics,
        )

    try:
        payload = json.loads(run.stdout)
    except json.JSONDecodeError as exc:
        raise SelectorError(
            f"tracker stdout is not one JSON document: {exc}",
            EXIT_MALFORMED_OUTPUT,
            diagnostics,
        ) from exc
    if not isinstance(payload, dict):
        raise SelectorError(
            "tracker JSON must be an object", EXIT_MALFORMED_OUTPUT, diagnostics
        )

    outcome = payload.get("outcome")
    if outcome == "not-configured":
        return NotConfiguredResult(outcome="not-configured", diagnostics=diagnostics)
    if outcome == "empty":
        if payload.get("candidates") != []:
            raise SelectorError(
                "empty tracker result must contain candidates=[]",
                EXIT_MALFORMED_OUTPUT,
                diagnostics,
            )
        return EmptyResult(outcome="empty", diagnostics=diagnostics)
    if outcome != "selected":
        raise SelectorError(
            f"unknown tracker JSON outcome: {outcome!r}",
            EXIT_MALFORMED_OUTPUT,
            diagnostics,
        )
    candidates = payload.get("candidates")
    if not isinstance(candidates, list) or len(candidates) != 1:
        raise SelectorError(
            "selected tracker result must contain exactly one candidate",
            EXIT_MALFORMED_OUTPUT,
            diagnostics,
        )
    candidate = candidates[0]
    if not isinstance(candidate, dict):
        raise SelectorError("candidate must be an object", EXIT_MALFORMED_OUTPUT, diagnostics)
    path = candidate.get("path")
    kind = candidate.get("kind")
    reason = candidate.get("reason")
    if not isinstance(path, str) or not path:
        raise SelectorError("candidate path is empty", EXIT_MALFORMED_OUTPUT, diagnostics)
    if kind not in ("file", "directory"):
        raise SelectorError(
            f"candidate kind must be 'file' or 'directory', got {kind!r}",
            EXIT_MALFORMED_OUTPUT,
            diagnostics,
        )
    if not isinstance(reason, str) or not reason:
        raise SelectorError("candidate reason is empty", EXIT_MALFORMED_OUTPUT, diagnostics)

    return SelectedResult(
        outcome="selected",
        path=path,
        kind=kind,
        reason=reason,
        diagnostics=diagnostics,
    )


def _report_failure(error: SelectorError, command: list[str], run: TrackerRun | None) -> None:
    """Explain a failure on stderr. Nothing here may touch stdout."""
    print(f"audit-and-fix selector: {error}", file=sys.stderr)
    print(f"  command: {' '.join(command)}", file=sys.stderr)
    if run is not None and run.stdout.strip():
        print("  tracker stdout:", file=sys.stderr)
        for line in run.stdout.splitlines():
            print(f"    {line}", file=sys.stderr)
    for line in error.diagnostics:
        print(f"  tracker stderr: {line}", file=sys.stderr)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="select_next.py",
        description=(
            "Ask the audit tracker for the next path to audit and print one "
            "validated JSON result. Non-zero exit means no selection was made."
        ),
    )
    parser.add_argument("audit_type", help="e.g. code-quality, doc-quality, readme-quality")
    parser.add_argument(
        "--kind",
        choices=["file", "directory"],
        help="Restrict the tracker to files or directories only",
    )
    parser.add_argument(
        "--under",
        metavar="PATH",
        help="Restrict the tracker's candidates to a repo-relative subtree",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    command = build_command(args.audit_type, args.kind, args.under)
    try:
        root = repo_root()
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return EXIT_TRACKER_FAILED

    try:
        run = invoke_tracker(command, root)
    except OSError as exc:
        print(
            f"audit-and-fix selector: could not run {command[0]!r}: {exc}",
            file=sys.stderr,
        )
        return EXIT_TRACKER_FAILED

    try:
        result = interpret(run)
    except SelectorError as error:
        _report_failure(error, command, run)
        return error.exit_code

    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
