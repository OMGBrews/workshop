#!/usr/bin/env python3
"""Inventory prose problem records without silently losing legacy or parked files."""
import json
import sys
from pathlib import Path

BUCKETS = {"now", "soon", "later", "never"}
GUIDES = {"README.md", "_TEMPLATE.md"}


def inventory(repo):
    root = repo / "docs/work/problems"
    if root.is_symlink():
        raise ValueError(f"symlinked collection: {root}")
    if not root.exists():
        return {"state": "absent", "records": []}
    if not root.is_dir():
        raise ValueError(f"collection is not a directory: {root}")
    records = []
    slugs = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if path.is_symlink():
            raise ValueError(f"symlink in collection: {relative}")
        if not path.is_file() or path.suffix != ".md" or path.name in GUIDES:
            continue
        if len(relative.parts) == 1:
            bucket = "unbucketed"
        elif len(relative.parts) == 2 and relative.parts[0] in BUCKETS:
            bucket = relative.parts[0]
        else:
            raise ValueError(f"unsupported record location: {relative}")
        if path.stem in slugs:
            raise ValueError(f"duplicate slug: {slugs[path.stem]} and {relative}")
        slugs[path.stem] = str(relative)
        records.append({"path": str(path.relative_to(repo)),
                        "slug": path.stem, "bucket": bucket})
    return {"state": "present" if records else "empty", "records": records}


def main():
    if len(sys.argv) != 2:
        print("usage: list-records.py REPO_ROOT", file=sys.stderr)
        return 2
    try:
        repo = Path(sys.argv[1]).resolve(strict=True)
        if not repo.is_dir():
            raise ValueError(f"repository root is not a directory: {repo}")
        result = inventory(repo)
    except (OSError, ValueError) as error:
        print(f"problem inventory failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
