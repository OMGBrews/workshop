#!/usr/bin/env bash
# Check supported relative Markdown file and image links in a repository.
#
# The grammar is shared with rewrite-moved-markdown-links.sh: single-line inline
# links, images, and reference definitions have an angle-bracketed destination,
# or a whitespace-free destination without parentheses. Optional titles are
# retained but not interpreted. URI, absolute, and fragment-only targets, plus
# links in fenced or inline code, are deliberately outside this small check.
# Footnote definitions (`[^1]: ...`) are not link definitions. Targets are
# percent-decoded before the existence test, so `my%20file.md` finds
# `my file.md`; the shared extractor itself never decodes, because rewrite mode
# writes targets back byte for byte.
# Symlink sources are skipped and named. Targets escaping the repository are
# skipped and named; submodule targets are checked when their mount is populated
# and skipped and named when `git submodule status` reports them unavailable.
#
# A repository may list sources to skip in `.markdown-links-skip` at its root,
# read from the working tree: one repository-relative path per line, a trailing
# `/` naming a directory, blank lines and `#` comments ignored (say why each entry
# is there). Wildcards, absolute paths, and `..` segments are refused (exit 2).
# Each skipped source is named; an entry matching no tracked Markdown file is a
# stale entry and fails the check, so the list cannot quietly outlive its reason.
#
# Exit 0: valid. Exit 1: broken links or stale skip entries. Exit 2: usage, an
# invalid skip file, or a source outside the shared grammar; every other source
# is still checked and reported before exit 2.
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: bash Tools/check-markdown-links.sh <repo-root>" >&2; exit 2; }
root="$(cd "$1" && pwd)"
git -C "$root" rev-parse --git-dir > /dev/null 2>&1 \
  || { echo "$root is not a git repository — tracked Markdown files are the check's scope" >&2; exit 2; }
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
extractor="$script_dir/rewrite-moved-markdown-links.sh"
failures=0
skipped=0
unparsed=0
skip_file_name=.markdown-links-skip
skip_file="$root/$skip_file_name"
declare -a skip_entries=()
declare -A skip_used=()

if [[ -f "$skip_file" ]]; then
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry="${entry%$'\r'}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "$entry" || "$entry" == '#'* ]] && continue
    if [[ "$entry" =~ [][*?] || "$entry" == /* || "$entry" =~ (^|/)\.\.(/|$) ]]; then
      printf '%s: unsupported entry (no wildcards, absolute paths, or .. segments): %s\n' \
        "$skip_file_name" "$entry" >&2
      exit 2
    fi
    skip_entries+=("$entry")
  done < "$skip_file"
fi

skip_entry_for() { # <source repo-relative> -> the matching entry, or nothing
  local source_rel="$1" entry
  for entry in "${skip_entries[@]}"; do
    case "$entry" in
      */) [[ "$source_rel" == "$entry"* ]] && { printf '%s\n' "$entry"; return; } ;;
      *) [[ "$source_rel" == "$entry" ]] && { printf '%s\n' "$entry"; return; } ;;
    esac
  done
  return 0 # no match is not an error: the caller's assignment runs under set -e
}

percent_decode() { # <target> -> target with each valid %XX decoded; %00 stays encoded
  local s="$1" out="" hex ch
  while [[ "$s" == *%* ]]; do
    out+="${s%%\%*}"
    s="${s#*%}"
    hex="${s:0:2}"
    if [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ && "$hex" != 00 ]]; then
      printf -v ch '%b' "\\x$hex"
      out+="$ch"
      s="${s:2}"
    else
      out+=%
    fi
  done
  printf '%s\n' "$out$s"
}

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
  resolved="$(normalize_repo_path "$source_rel" "$(percent_decode "$target")")"
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
  entry="$(skip_entry_for "$source_rel")"
  if [[ -n "$entry" ]]; then
    skip_used["$entry"]=1
    printf 'skipped Markdown source (listed in %s): %s\n' "$skip_file_name" "$source_rel"
    skipped=$((skipped + 1))
    continue
  fi
  if [[ -L "$source" ]]; then
    printf 'skipped symlink Markdown source: %s\n' "$source_rel"
    skipped=$((skipped + 1))
    continue
  fi
  if ! targets="$(bash "$extractor" --extract "$source")"; then
    unparsed=$((unparsed + 1))
    continue
  fi
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    target="${record#*$'\t'}"
    check_target "$source" "$source_rel" "$target"
  done <<< "$targets"
done < <(git -C "$root" ls-files -z -- '*.md')

for entry in "${skip_entries[@]}"; do
  [[ -n "${skip_used[$entry]:-}" ]] && continue
  printf 'stale %s entry matches no tracked Markdown source: %s\n' "$skip_file_name" "$entry" >&2
  failures=$((failures + 1))
done

if [ "$unparsed" -gt 0 ]; then
  echo "$unparsed Markdown source(s) outside the supported link grammar; links not fully checked" >&2
  exit 2
fi
[ "$failures" -eq 0 ] || exit 1
echo "Markdown links valid; $skipped source or target(s) skipped"
