#!/usr/bin/env bash
# Check supported relative Markdown file and image links in a repository.
#
# The grammar is shared with rewrite-moved-markdown-links.sh: single-line inline
# links, images, and reference definitions have an angle-bracketed destination,
# or a whitespace-free destination without parentheses. Optional titles are
# retained but not interpreted. URI, absolute, and fragment-only targets, plus
# links in fenced or inline code, are deliberately outside this small gate.
# Symlink sources are skipped and named. Targets escaping the repository are
# skipped and named; submodule targets are checked when their mount is populated
# and skipped and named when `git submodule status` reports them unavailable.
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: bash Tools/check-markdown-links.sh <repo-root>" >&2; exit 2; }
root="$(cd "$1" && pwd)"
git -C "$root" rev-parse --git-dir > /dev/null 2>&1 \
  || { echo "$root is not a git repository — tracked Markdown files are the check's scope" >&2; exit 2; }
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
extractor="$script_dir/rewrite-moved-markdown-links.sh"
failures=0
skipped=0

normalize_repo_path() { # <source repo-relative> <target> -> lexical repo-relative path
  local source="$1" target="$2" base part result="" i last
  local -a stack=() pieces=()
  base="$(dirname "$source")"
  IFS=/ read -r -a pieces <<< "$base/$target"
  for part in "${pieces[@]}"; do
    case "$part" in
      ''|.) ;;
      ..)
        if (( ${#stack[@]} > 0 )) && [[ "${stack[${#stack[@]} - 1]}" != .. ]]; then
          last=$((${#stack[@]} - 1))
          unset "stack[$last]"
        else
          stack+=(..)
        fi
        ;;
      *) stack+=("$part") ;;
    esac
  done
  for ((i = 0; i < ${#stack[@]}; i++)); do
    result+="${result:+/}${stack[i]}"
  done
  printf '%s\n' "$result"
}

submodule_state() { # <repo-relative resolved path> -> populated|unavailable|none
  local resolved="$1" key mount status
  [[ -f "$root/.gitmodules" ]] || { echo none; return; }
  while IFS=$'\t' read -r key mount; do
    : "$key" # the config key is intentionally ignored; the path is the contract
    [[ "$resolved" == "$mount" || "$resolved" == "$mount/"* ]] || continue
    status="$(git -C "$root" submodule status -- "$mount" 2>/dev/null || true)"
    if [[ "${status:0:1}" == '-' ]]; then
      echo unavailable
    else
      echo populated
    fi
    return
  done < <(git config -f "$root/.gitmodules" --get-regexp '^submodule\..*\.path$' | sed 's/ /\t/')
  echo none
}

check_target() { # <source absolute> <source repo-relative> <target>
  local source="$1" source_rel="$2" target="$3" resolved state
  target="${target%%#*}"
  target="${target%%\?*}"
  case "$target" in
    ''|/*|*://*|mailto:*|tel:*) return 0 ;;
  esac
  resolved="$(normalize_repo_path "$source_rel" "$target")"
  if [[ "$resolved" == .. || "$resolved" == ../* ]]; then
    printf 'skipped Markdown link escaping repository: %s -> %s\n' "$source_rel" "$target"
    skipped=$((skipped + 1))
    return
  fi
  state="$(submodule_state "$resolved")"
  if [[ "$state" == unavailable ]]; then
    printf 'skipped Markdown link into unavailable submodule: %s -> %s\n' "$source_rel" "$target"
    skipped=$((skipped + 1))
    return
  fi
  if [[ ! -e "$root/$resolved" ]]; then
    printf 'broken Markdown link: %s -> %s\n' "$source_rel" "$target" >&2
    failures=$((failures + 1))
  fi
}

while IFS= read -r -d '' source_rel; do
  source="$root/$source_rel"
  if [[ -L "$source" ]]; then
    printf 'skipped symlink Markdown source: %s\n' "$source_rel"
    skipped=$((skipped + 1))
    continue
  fi
  if ! targets="$(bash "$extractor" --extract "$source")"; then
    exit 2
  fi
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    target="${record#*$'\t'}"
    check_target "$source" "$source_rel" "$target"
  done <<< "$targets"
done < <(git -C "$root" ls-files -z -- '*.md')

[ "$failures" -eq 0 ] || exit 1
echo "Markdown links valid; $skipped source or target(s) skipped"
