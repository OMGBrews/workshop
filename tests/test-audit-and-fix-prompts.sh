#!/usr/bin/env bash
# Validate the prompt-file structure that audit-and-fix treats as executable input.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path


repo = Path(sys.argv[1])
prompts = repo / ".agents" / "skills" / "audit-and-fix" / "prompts"
failures: list[str] = []

for path in sorted(prompts.glob("*.md")):
    if path.name == "README.md":
        continue
    text = path.read_text(encoding="utf-8")
    try:
        lens_body = text.split("\n## Lenses\n", 1)[1]
    except IndexError:
        failures.append(f"{path.name}: missing a unique ## Lenses section")
        continue

    lenses = [line for line in lens_body.splitlines() if re.match(r"^\d+\. ", line)]
    numbers = [int(line.split(".", 1)[0]) for line in lenses]
    if not lenses:
        failures.append(f"{path.name}: has no numbered lenses")
        continue
    if numbers != list(range(1, len(lenses) + 1)):
        failures.append(f"{path.name}: lens numbering is not contiguous from 1")
    for number, lens in zip(numbers, lenses, strict=True):
        if "<subject>" not in lens:
            failures.append(f"{path.name}: lens {number} has no <subject> placeholder")

    style_lenses = [line for line in lenses if "<style-guide>" in line]
    if len(style_lenses) > 1:
        failures.append(f"{path.name}: <style-guide> appears in more than one lens")
    if text.count("<style-guide>") != len(style_lenses):
        failures.append(f"{path.name}: <style-guide> appears outside a numbered lens")

if failures:
    print("audit-and-fix prompt contract failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    raise SystemExit(1)

print("audit-and-fix prompt contract passed")
PY
