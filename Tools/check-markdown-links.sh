#!/usr/bin/env bash
# Check supported relative Markdown links in one captured working-tree view.
# The Python consumer keeps path bytes intact; the shared shell extractor still
# owns link grammar, and markdown-anchors.py still owns rendered heading IDs.
# Run with --help for the repository scope and exit-code contract.
set -euo pipefail

# Keep tool code separate from the repository data being checked. A sentinel
# protects a tool directory ending in a newline from command-substitution trim.
script_path="${BASH_SOURCE[0]}"
script_dir="${script_path%/*}"
[[ "$script_dir" != "$script_path" ]] || script_dir=.
script_dir="$(cd -P -- "$script_dir" && printf '%s.' "$PWD")"
script_dir="${script_dir%.}"
exec python3 "$script_dir/check-markdown-links.py" "$@"
