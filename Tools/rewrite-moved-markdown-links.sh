#!/usr/bin/env bash
# Rewrite supported relative Markdown targets after a document moves.
#
# Usage:
#   rewrite-moved-markdown-links.sh REPO_ROOT OLD_PATH NEW_PATH STAGED_FILE
#
# A tool that relocates a document owns the link rebasing it necessitates.  This
# helper supports single-line inline links, images, and reference definitions.
# Their destinations must be angle-bracketed, or whitespace-free without
# parentheses; optional titles are preserved.  URI, absolute, and fragment-only
# targets are left alone.  Active link syntax outside that grammar is refused,
# rather than guessed at or silently copied unchanged.
set -euo pipefail

usage() {
  echo "usage: $0 REPO_ROOT OLD_PATH NEW_PATH STAGED_FILE" >&2
  echo "       $0 --extract SOURCE_FILE" >&2
  exit 2
}

mode=rewrite
if [[ "${1:-}" == "--extract" ]]; then
  [[ "$#" -eq 2 ]] || usage
  source_file="$2"
  old_path="$source_file"
  new_path="$source_file"
  staged_file="$source_file"
  mode=extract
elif [[ "$#" -eq 4 ]]; then
  repo_root="$1"
  old_path="$2"
  new_path="$3"
  staged_file="$4"
  [[ -d "$repo_root" && -f "$staged_file" ]] || { echo "error: invalid rewriter paths" >&2; exit 2; }
else
  usage
fi

tmp="$(mktemp "${staged_file}.rewrite.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# The scanner is intentionally shared by rewrite and --extract.  Keeping the
# grammar in one implementation means the checker cannot accept syntax the
# migrator would refuse.
awk -v mode="$mode" -v old_path="$old_path" -v new_path="$new_path" '
  function fail(message) {
    printf "error: %s:%d: unsupported Markdown link syntax: %s\n", old_path, NR, message > "/dev/stderr"
    bad = 1
    exit 1
  }
  function normalize(path,    pieces,n,i,p,count,out) {
    n = split(path, pieces, "/"); count = 0
    for (i = 1; i <= n; i++) {
      p = pieces[i]
      if (p == "" || p == ".") continue
      if (p == "..") {
        if (count > 0 && stack[count] != "..") count--
        else stack[++count] = ".."
      } else stack[++count] = p
    }
    out = ""
    for (i = 1; i <= count; i++) out = out (i == 1 ? "" : "/") stack[i]
    for (i = 1; i <= count; i++) delete stack[i]
    return out
  }
  function parent(path,    p) { p = path; sub(/\/[^/]*$/, "", p); return p == path ? "" : p }
  function rebase(target,    suffix_at,path,suffix,resolved,from,a,b,na,nb,i,common,out) {
    if (target == "" || target ~ /^\/|^[^[:space:]]*:\/\// || target ~ /^(mailto|tel):/ || target ~ /^#/) return target
    suffix_at = match(target, /[?#]/)
    if (suffix_at) { path = substr(target, 1, suffix_at - 1); suffix = substr(target, suffix_at) }
    else { path = target; suffix = "" }
    resolved = normalize(parent(old_path) "/" path)
    from = normalize(parent(new_path))
    na = split(from, a, "/"); nb = split(resolved, b, "/"); common = 0
    while (common < na && common < nb && a[common + 1] == b[common + 1]) common++
    out = ""
    for (i = common + 1; i <= na; i++) out = out (out == "" ? "" : "/") ".."
    for (i = common + 1; i <= nb; i++) out = out (out == "" ? "" : "/") b[i]
    if (out == "") out = "."
    return out suffix
  }
  function parse_destination(inside,    n,start,end,ch,target,tail) {
    n = length(inside); start = 1
    while (start <= n && substr(inside, start, 1) ~ /[[:space:]]/) start++
    if (start > n) return 0
    if (substr(inside, start, 1) == "<") {
      end = index(substr(inside, start + 1), ">")
      if (!end) return 0
      end += start
      target = substr(inside, start + 1, end - start - 1)
      if (target ~ /[()\\]/) return 0
      tail = substr(inside, end + 1)
      if (tail != "" && tail !~ /^[[:space:]]/) return 0
      target_start = start + 1; target_end = end - 1; angle = 1
    } else {
      end = start
      while (end <= n && substr(inside, end, 1) !~ /[[:space:]]/) end++
      target = substr(inside, start, end - start)
      if (target == "" || target ~ /[()\\]/) return 0
      target_start = start; target_end = end - 1; angle = 0
    }
    parsed_target = target
    return 1
  }
  function rewrite_inline(line, start, close_label,    open,scan,ch,end_paren,inside,before,after,newtarget) {
    open = close_label + 1
    if (substr(line, open, 1) != "(") return 0
    scan = open + 1; end_paren = 0
    while (scan <= length(line)) {
      ch = substr(line, scan, 1)
      if (ch == ")") { end_paren = scan; break }
      scan++
    }
    if (!end_paren) fail("multiline or unclosed inline link")
    inside = substr(line, open + 1, end_paren - open - 1)
    if (!parse_destination(inside)) fail("inline link destination is outside the supported grammar")
    if (mode == "extract") { printf "%d\t%s\n", NR, parsed_target; return end_paren }
    newtarget = rebase(parsed_target)
    if (newtarget == parsed_target) {
      rewritten = substr(line, start, end_paren - start + 1)
      return end_paren
    }
    before = substr(inside, 1, target_start - 1)
    after = substr(inside, target_end + 1)
    rewritten = substr(line, start, open) before newtarget after ")"
    return end_paren
  }
  function process_reference(line,    pos,inside,before,after,newtarget) {
    if (line !~ /^[[:space:]]*\[[^]]+\]:/) return line
    pos = index(line, ":")
    inside = substr(line, pos + 1)
    if (!parse_destination(inside)) fail("reference destination is outside the supported grammar")
    if (mode == "extract") { printf "%d\t%s\n", NR, parsed_target; return line }
    newtarget = rebase(parsed_target)
    if (newtarget == parsed_target) return line
    before = substr(inside, 1, target_start - 1)
    after = substr(inside, target_end + 1)
    return substr(line, 1, pos) before newtarget after
  }
  /^[[:space:]]*(```|~~~)/ { fence = !fence; if (mode == "rewrite") print; next }
  fence { if (mode == "rewrite") print; next }
  {
    line = $0
    if (line ~ /^[[:space:]]*\[[^]]+\]:/) {
      result = process_reference(line)
      if (mode == "rewrite") print result
      next
    }
    result = ""; i = 1
    while (i <= length(line)) {
      ch = substr(line, i, 1)
      if (ch == "`") {
        end_code = index(substr(line, i + 1), "`")
        if (!end_code) { result = result substr(line, i); break }
        end_code += i
        result = result substr(line, i, end_code - i + 1); i = end_code + 1; continue
      }
      if (ch == "[" || (ch == "!" && substr(line, i + 1, 1) == "[")) {
        label = (ch == "!" ? i + 1 : i)
        close_label = index(substr(line, label + 1), "]")
        if (close_label) {
          close_label += label
          if (substr(line, close_label + 1, 1) == "(") {
            end_paren = rewrite_inline(line, i, close_label)
            if (mode == "rewrite") result = result rewritten
            i = end_paren + 1; continue
          }
        }
      }
      result = result ch; i++
    }
    if (mode == "rewrite") print result
  }
  END { if (bad) exit 1 }
' "$staged_file" > "$tmp"

if [[ "$mode" == rewrite ]]; then
  mv "$tmp" "$staged_file"
else
  cat "$tmp"
fi
