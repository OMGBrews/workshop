#!/usr/bin/env bash
#
# cloud-git-lfs.sh — make Git LFS work in a Claude Code on the Web session:
# authenticate it through the session proxy, upload on push, and hydrate the
# checkout with a positive census. docs/cloud-git-lfs.md carries the incidents
# and evidence behind each step.
#
# Usage:
#   cloud-git-lfs.sh credential-fallback [<repo>]
#   cloud-git-lfs.sh pre-push-hook       [<repo>]
#   cloud-git-lfs.sh hydrate [--verify] [--include=<patterns>] [<repo>]
#   cloud-git-lfs.sh session [--include=<patterns>] [<repo>]
#
#   <repo>      checkout root; default: the current directory's top level.
#   --include   comma-separated git-lfs include patterns, e.g.
#               'addons/**,assets/**'; default: every LFS-tracked file.
#   --verify    census only; pull nothing.
#
# `session` runs the other three in order and is the one call a repository's
# scripts/agent/cloud-env.sh needs. The CALLER gates on an ephemeral session:
# the credential fallback belongs in a cloud checkout, never a local one.
#
# Why each step exists:
#
#   credential-fallback — the session proxy authorizes GitHub requests itself,
#     but git-lfs asks a credential helper first and, when none answers, fails
#     with `could not read Username` / `Git credentials ... not found` before
#     the request reaches the proxy. This appends a repository-local helper for
#     https://github.com that answers `username=git password=placeholder` only
#     after every earlier helper has returned nothing. Idempotent. It covers
#     pull, the pre-push upload, and ordinary pushes, which git-lfs also probes.
#
#   pre-push-hook — the hook that uploads LFS objects. Workshop's bootstrap
#     points core.hooksPath at the mount's Tools/hooks, and git then ignores
#     .git/hooks entirely; Workshop's post-checkout and post-merge also occupy
#     two of git-lfs's hook names, so a plain `git lfs install` stops partway
#     with an error. This installs pre-push alone into the effective hooks
#     directory, setting core.hooksPath first exactly as the bootstrap would
#     when this tool runs from the repository's own Workshop mount. An existing
#     pre-push that is not git-lfs's is never overwritten.
#
#   hydrate — `git lfs pull`, then the positive assertion: at least one file is
#     LFS-tracked under the patterns, none remains a pointer, and the index
#     agrees with the hydrated files (stale_entries explains the failure that
#     check exists for; a pull repairs it, --verify reports it). A pointer is a
#     ~130-byte text file, and reading one does not error.
#
# Exit: 0 when the step (or every step) achieved its positive property;
#       1 when it did not, with the reason on stderr; 2 on usage errors or a
#       missing git-lfs.

set -uo pipefail

TOOLS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_KEY='credential.https://github.com.helper'
# shellcheck disable=SC2016  # a git config value, expanded by git, not here
FALLBACK_HELPER='!f() { if [ "$1" = get ]; then printf "%s\n" username=git password=placeholder; fi; }; f'

say() { echo "cloud-git-lfs: $*"; }
err() { echo "cloud-git-lfs: $*" >&2; }
usage() { sed -n '8,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

credential_fallback() {
  if git -C "$REPO" config --local --get-all "$HELPER_KEY" 2>/dev/null | grep -Fqx "$FALLBACK_HELPER"; then
    say "credential fallback already installed"
  elif git -C "$REPO" config --local --add "$HELPER_KEY" "$FALLBACK_HELPER"; then
    say "credential fallback installed after existing GitHub helpers"
  else
    err "could not write the credential fallback to $REPO/.git/config"
    return 1
  fi
}

pre_push_hook() {
  local hooks tmp
  # The bootstrap's own wiring, when this tool is the repository's mount.
  if ! git -C "$REPO" config core.hooksPath >/dev/null && [ -f "$TOOLS_DIR/check-skill-roster-freshness.sh" ]; then
    case "$TOOLS_DIR/" in
      "$REPO_PHYS"/*) git -C "$REPO" config core.hooksPath "${TOOLS_DIR#"$REPO_PHYS"/}/hooks" ;;
    esac
  fi
  hooks="$(git -C "$REPO" rev-parse --path-format=absolute --git-path hooks)"
  if grep -q 'git lfs pre-push' "$hooks/pre-push" 2>/dev/null; then
    say "LFS pre-push hook present in $hooks"
    return 0
  fi
  if [ -e "$hooks/pre-push" ]; then
    err "$hooks/pre-push exists and is not git-lfs's; not overwriting it. Pushes will not upload LFS objects until it calls 'git lfs pre-push'."
    return 1
  fi
  # Let git-lfs write its hooks into an empty directory, then take pre-push only.
  tmp="$(mktemp -d)"
  if ! git -C "$REPO" -c core.hooksPath="$tmp" lfs install --local >/dev/null 2>&1 || [ ! -f "$tmp/pre-push" ]; then
    rm -rf "$tmp"
    err "git lfs install produced no pre-push hook"
    return 1
  fi
  mkdir -p "$hooks" && cp "$tmp/pre-push" "$hooks/pre-push" && chmod +x "$hooks/pre-push"
  rm -rf "$tmp"
  if grep -q 'git lfs pre-push' "$hooks/pre-push" 2>/dev/null; then
    say "LFS pre-push hook installed in $hooks"
  else
    err "LFS pre-push hook could not be written to $hooks"
    return 1
  fi
}

# `git lfs ls-files --long`: "<64-hex oid> <-|*> <path>". `*` is a hydrated file;
# `-` is any file whose content is not that object, which includes an edited
# file as well as a pointer. A pointer is counted only when the file's first
# line is the pointer header, so uncommitted edits never read as unhydrated.
# Builtins only: a pointer-only clone lists thousands of `-` entries.
census() {
  local line path first total=0 pointers=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[0-9a-f]{64}\ [-*]\  ]] || continue
    total=$((total + 1))
    [ "${line:65:1}" = "-" ] || continue
    path="${line:67}"
    first=""
    { IFS= read -r first < "$REPO/$path"; } 2>/dev/null || true
    case "$first" in "version https://git-lfs.github.com/spec/"*) pointers=$((pointers + 1)) ;; esac
  done < <(git -C "$REPO" lfs ls-files --long "${include_args[@]}")
  echo "$total $pointers"
}

# LFS-tracked paths under the patterns whose index entry is stale: git's stat
# comparison reports them changed, yet their content matches the index. This is
# what `git lfs pull` leaves when its index update fails, for example on a held
# index.lock; it prints "Error updating the Git index" and still exits 0. The
# index then keeps the pointer's size, git treats a size change as modified
# without comparing content, so `git status` lists every such file while
# `git diff` and `update-index --refresh` see nothing to fix. A real edit has a
# content diff and is not stale. Writes the paths, one per line, to <file>.
stale_entries() { # <file>
  local dir
  dir="$(mktemp -d)"
  git -C "$REPO" lfs ls-files --name-only "${include_args[@]}" | sort -u > "$dir/lfs"
  git -C "$REPO" -c core.quotePath=false diff-files --name-only | sort -u > "$dir/stat"
  git -C "$REPO" -c core.quotePath=false diff --name-only | sort -u > "$dir/content"
  comm -12 "$dir/lfs" "$dir/stat" | comm -23 - "$dir/content" > "$1"
  rm -rf "$dir"
}

# Rewrites stale entries from the index (identical content; git records the real
# size), unless verifying. Fails while any remain.
index_agrees() {
  local list n label="$1"
  list="$(mktemp)"
  stale_entries "$list"
  n="$(wc -l < "$list")"
  if [ "$n" -gt 0 ] && [ "$verify" -eq 0 ]; then
    say "$n hydrated files under $label have stale index entries; rewriting them from the index"
    git -C "$REPO" --literal-pathspecs checkout --pathspec-from-file="$list" || err "git checkout exited $?"
    stale_entries "$list"
    n="$(wc -l < "$list")"
  fi
  if [ "$n" -gt 0 ]; then
    err "$n files under $label are hydrated but their index entries are stale, so git status reports them modified:"
    head -n 5 "$list" | sed 's/^/    /' >&2
    if [ "$verify" -eq 1 ]; then err "run hydrate without --verify to repair them"; fi
    rm -f "$list"
    return 1
  fi
  rm -f "$list"
}

hydrate() {
  local total pointers label="${include:-every LFS-tracked file}" status
  # Filters in this checkout's own config, independent of HOME. No hooks: see pre-push-hook.
  git -C "$REPO" lfs install --local --skip-repo >/dev/null 2>&1 || true
  read -r total pointers < <(census)
  if [ "$total" -eq 0 ]; then
    err "no LFS-tracked files under $label; the census cannot confirm anything"
    return 1
  fi
  if [ "$pointers" -gt 0 ] && [ "$verify" -eq 0 ]; then
    say "$pointers of $total files under $label are pointers; pulling"
    # Full output and exit status are the evidence; nothing here trims them.
    GIT_TERMINAL_PROMPT=0 git -C "$REPO" lfs pull "${include_args[@]}"
    status=$?
    [ "$status" -eq 0 ] || err "git lfs pull exited $status"
    read -r total pointers < <(census)
  fi
  if [ "$pointers" -gt 0 ]; then
    err "$pointers of $total files under $label are still pointers"
    return 1
  fi
  index_agrees "$label" || return 1
  say "$total files under $label hydrated, 0 pointers, index current"
}

[ $# -ge 1 ] || usage
command="$1"; shift
verify=0; include=""; REPO=""
for arg in "$@"; do
  case "$arg" in
    --verify) verify=1 ;;
    --include=*) include="${arg#--include=}" ;;
    -h|--help) usage ;;
    -*) err "unknown option $arg"; usage ;;
    *) [ -z "$REPO" ] || usage; REPO="$arg" ;;
  esac
done
case "$command" in
  credential-fallback|pre-push-hook|hydrate|session) ;;
  -h|--help) usage ;;
  *) err "unknown command $command"; usage ;;
esac
if [ "$verify" -eq 1 ] && [ "$command" != hydrate ]; then err "--verify applies to hydrate only"; usage; fi
if [ -n "$include" ] && [ "$command" != hydrate ] && [ "$command" != session ]; then err "--include applies to hydrate and session only"; usage; fi

REPO="$(git -C "${REPO:-.}" rev-parse --show-toplevel 2>/dev/null)" || { err "not a git checkout: ${REPO:-.}"; exit 2; }
REPO_PHYS="$(cd -P "$REPO" && pwd)"
include_args=()
[ -z "$include" ] || include_args=(--include="$include")
if [ "$command" != credential-fallback ] && ! command -v git-lfs >/dev/null 2>&1; then
  err "git-lfs is not installed; in a cloud session the environment's setup script must install it"
  exit 2
fi

case "$command" in
  credential-fallback) credential_fallback ;;
  pre-push-hook) pre_push_hook ;;
  hydrate) hydrate ;;
  session)
    failed=0
    credential_fallback || failed=1
    pre_push_hook || failed=1
    hydrate || failed=1
    [ "$failed" -eq 0 ]
    ;;
esac
