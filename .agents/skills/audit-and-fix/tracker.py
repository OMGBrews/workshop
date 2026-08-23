#!/usr/bin/env python3
"""Entry point for the audit tracker: ``python3 .agents/skills/audit-and-fix/tracker.py <cmd> …``.

The caller-facing command everywhere — this skill's SKILL.md, ``audit-next``,
``audit-done``, and pia-maker's audit-queue runner — is exactly that spelling,
run from the consumer repo root. No ``PYTHONPATH`` and no venv: this launcher
bootstraps ``sys.path`` from its own **physical** location (``resolve()``
follows the consumer's ``.agents/skills`` link into the pinned Workshop
mount, where the package actually lives), asserts the Python floor, and
disables bytecode writing.

The bytecode switch is load-bearing, not cosmetic: without it, importing the
package writes ``__pycache__/`` *through* the symlink into the pinned
submodule, which has no ``.gitignore`` — dirtying every consumer's mount view
and tripping clean-tree gates like audit-queue's ``git diff --quiet HEAD``
completion check. Stale cross-mount bytecode has bitten before (the
``EOFError: marshal data too short`` note in pia-maker's pin-advance
procedure).
"""

import sys

if sys.version_info < (3, 11):
    sys.exit(
        "audit_tracker: Python 3.11+ is required (tomllib); running "
        + sys.version.split()[0]
    )

sys.dont_write_bytecode = True

from pathlib import Path  # noqa: E402  # after the floor guard on purpose

sys.path.insert(0, str(Path(__file__).resolve().parent))

from audit_tracker.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
