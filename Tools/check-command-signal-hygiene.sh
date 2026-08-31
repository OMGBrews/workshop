#!/usr/bin/env bash
# check-command-signal-hygiene.sh — would this command destroy the signal it is
# supposed to read?
#
# Usage:
#   bash Tools/check-command-signal-hygiene.sh '<command string>'   # one command
#   bash Tools/check-command-signal-hygiene.sh --scan <file> ...    # a file's commands
#
# Exit 0  -> clean. No screen matched.
# Exit 1  -> deny. A screen matched; the reason is printed, with the sanctioned
#            form to use instead.
# Exit 2  -> cannot decide (empty input, unreadable file). A *hook* treats this
#            as clean — refusing to run a command nobody could parse is worse
#            than letting it through. A *lint* may treat it as 1.
#
# This is the same exit contract as Tools/docs-only-diff.sh, deliberately: one
# house shape for "predicate scripts a caller branches on".
#
# WHY ONE SCRIPT WITH TWO MODES
#
# The single-command mode is invoked by a PreToolUse hook, per command, before
# it runs. The --scan mode is invoked by a check, per file, over committed skill
# bodies and shell scripts. They screen for the same two shapes, so they are the
# same code: a lint that disagreed with the hook about what is dangerous would
# teach one lesson at author time and a different one at run time.
#
# THE TWO SCREENS, AND WHY ONLY TWO
#
#   f1  a verdict-bearing command whose output is PIPED into tail/head. The pipeline
#       reports tail's status, so a red run announces itself as success, and the
#       output explaining the failure is discarded.
#   f3  a verdict-bearing command run in the BACKGROUND with no EXIT= verdict written
#       into the artifact that will be read. The harness reports the whole
#       pipeline's status and swallows a trailing echo.
#
# Both are shapes where the pass state is reachable by the failure the command
# exists to detect. They are the two the fleet's journals record most often and
# the two a regex can recognise without guessing at intent.
#
# Deliberately NOT screened: unhandled `2>/dev/null` and `-q` (the rule as
# written does not describe the sharpest observed case, so mechanising it now
# would freeze a wrong screen), origin/<branch> read without a fetch, and push
# verification by SHA equality (both need session history, which a per-command
# hook does not have).
#
# WHY NOT REUSE scripts/detect-signal-hygiene-recurrence.sh's SCREENS
#
# That script is a measurement instrument. Its header freezes its screens so its
# numbers stay comparable against a recorded baseline, and its heuristics are
# deliberately generous — a hit there means "a human should look", and its f1
# screen flags ordinary recall commands (8 of 10 benign commands hit, verified).
# Generous is right for triage and wrong for denial. These screens are written
# fresh and narrow, and the corpus assertion in the tests is what holds them so.
#
# THE SANCTIONED FORM IS NOT A NEAR MISS OF EITHER SCREEN
#
#   <verdict-bearing command> > /tmp/check.log 2>&1; echo "EXIT=$?"; tail -40 /tmp/check.log
#
# ends in `tail`, and must never fire. The discriminator is the PIPE, not the
# word: here tail is its own command, after the verdict was captured, reading a
# file. Screening on `| tail` rather than on `tail` is the whole of it, and the
# tests assert this form clean in both modes.
#
# COUNTER-EXAMPLES
#
# A file that quotes a bad idiom in order to warn about it — this file, the
# standing rules, a regression test that demonstrates the old flow false-passing
# — must not fire. Mark those deliberately:
#
#   shell:    # signal-hygiene: counter-example      (same line, or the line above)
#   markdown: <!-- signal-hygiene: counter-example --> (the line above the fence)
#
# The marker is explicit rather than inferred because "is this quoted or meant?"
# is not decidable from the text, and a screen that guesses would either miss
# real instructions or fire on every document that teaches the rule.

set -euo pipefail

SANCTIONED='<verdict-bearing command> > /tmp/check.log 2>&1; echo "EXIT=$?"; tail -40 /tmp/check.log'
MARKER='signal-hygiene: counter-example'

# Commands whose exit code and output are the verification of something: test
# runners, builds, type checks, linters, the repo's own verify-/test-/check-
# scripts, and the two git verbs whose output IS the confirmation. `git log`,
# `git status`, `ls`, `cat` and friends are deliberately absent — piping those
# into head is ordinary recall, not a discarded verdict.
#
# The boundaries are `not a word character` rather than `whitespace`, and that
# is load-bearing: the first draft used whitespace and silently missed
# `$(git push ... | tail -2)`, because the character before `git` is `(`. It
# reported hq's corpus clean while hq's own regression test contained the exact
# idiom — this screen false-passing on the defect it exists to detect, which is
# the pattern it was written to stop. Command substitution, backticks, quotes
# and `{` are all ordinary ways a command starts.
B='(^|[^A-Za-z0-9_-])'      # left boundary
E='([^A-Za-z0-9_-]|$)'      # right boundary
VERDICT_BEARING_RE="$B(pytest|tsc|basedpyright|pyright|mypy|ruff|shellcheck|eslint|jest|vitest|phpunit|rspec|ctest)$E"
VERDICT_BEARING_RE+="|$B(npm|yarn|pnpm|bun)[[:space:]]+(run[[:space:]]+)?(test|build|lint|typecheck|check)$E"
VERDICT_BEARING_RE+="|${B}make[[:space:]]+(test|check|build|lint|ci|all)$E"
VERDICT_BEARING_RE+="|$B(cargo|go|dotnet|mvn|gradle)[[:space:]]+(test|build|check|vet|clippy|verify)$E"
VERDICT_BEARING_RE+="|${B}git[[:space:]]+(commit|push)$E"
VERDICT_BEARING_RE+="|$B(run-tests|verify-[A-Za-z0-9_.-]+|test-[A-Za-z0-9_.-]+|check-[A-Za-z0-9_.-]+)\.sh$E"

trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

is_verdict_bearing() { [[ $1 =~ $VERDICT_BEARING_RE ]]; }

# One segment per line. `&&`, `||`, `;` and newlines separate commands; a single
# `|` does not, because a pipeline is one command and its stages are what the f1
# screen compares. `||` is rewritten before any single-`|` inspection, so the
# two are never confused.
split_segments() {
  awk '{ gsub(/&&/,"\n"); gsub(/\|\|/,"\n"); gsub(/;/,"\n"); print }' <<<"$1"
}

# Blanks the contents of quoted string literals, keeping the quotes. A quoted
# literal is an ARGUMENT — a commit message, a description, a pattern to grep
# for — not a command that will run. The f1 screen reads the dequoted text, so
# writing *about* the bad idiom does not trip it.
#
# Not hypothetical, and not cheap to get wrong: with this missing, the hook
# denied the very command that was testing it (`probe 'npm test | tail -5'`),
# and would deny any attempt to document, grep for, or test the pattern. A
# mechanism that blocks the people fixing the problem is worse than none.
#
# KNOWN GAP, accepted deliberately: `bash -c "npm test | tail -5"` is not
# screened, because its quoted text really is a command. Telling that apart from
# a commit message needs to know each command's argument semantics, which a
# regex does not. The f1 screen therefore under-fires on that one shape rather
# than over-firing on every mention of it — the safer direction for a deny hook,
# and the --scan lint over committed files is unaffected for the ordinary case.
dequote() {
  awk '{
    out = ""; n = length($0); q = ""
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (q == "") {
        if (c == "\"" || c == "\047") { q = c; out = out c }
        else out = out c
      } else if (c == q) { q = ""; out = out c }
    }
    print out
  }' <<<"$1"
}

# Sets REASON when it returns 0 (= a screen matched).
REASON=""
screen_segment() {
  local seg stage1 rest
  seg=$(trim "$1")
  [[ -n $seg ]] || return 1
  REASON=""
  # Only the f1 screen lives here, and it cannot match without a pipe.
  [[ $seg == *"|"* ]] || return 1

  # --- f1: a verdict-bearing producer piped into tail/head -----------------
  if [[ $seg == *"|"* ]]; then
    stage1=${seg%%|*}
    rest=${seg#*|}
    if [[ $rest =~ (^|[[:space:]|])(tail|head)([[:space:]]|$) ]] && is_verdict_bearing "$stage1"; then
      REASON="A verdict-bearing command is piped into tail/head, so the pipeline reports tail's exit status, not the producer's: a failed run announces itself as success and the output explaining the failure is discarded. Redirect first, then read:
  $SANCTIONED
The trailing tail is fine there — it is a separate command reading a file after the verdict was captured. What is not fine is the pipe."
      return 0
    fi
  fi

  return 1
}

# --- f3: a backgrounded verdict-bearing run with no verdict in its artifact --
#
# This screen is deliberately whole-command, not per-segment. Backgrounding
# applies to the command the harness was handed, and the defect the rule names
# lives precisely in the gap between the two:
#
#   <verdict-bearing command> > out.txt 2>&1; echo "EXIT=$?" &
#
# Per segment that reads as an unbackgrounded producer plus a backgrounded echo, and
# both look fine. As one command it is the 2026-07-22 observation exactly — the
# redirect binds to the producer alone, so the verdict is written somewhere nobody
# reads. Only the braced group puts the verdict in the artifact.
screen_background() {
  local cmd=$1
  is_verdict_bearing "$cmd" || return 1
  if [[ $cmd =~ \{[^}]*EXIT=[^}]*\}[[:space:]]*\> ]]; then
    return 1   # braced verdict, redirected into the artifact — the sanctioned form
  fi
  if [[ $cmd == *'EXIT='* ]]; then
    REASON="A backgrounded verdict-bearing command captures a verdict, but not inside braces: the redirect binds to the command alone, so the verdict is written somewhere nobody reads. Brace the group so the echo lands in the same artifact:
  { <verdict-bearing command>; echo \"EXIT=\$?\"; } > /tmp/check.log 2>&1
then read the file."
  else
    REASON="A backgrounded verdict-bearing command writes no EXIT= verdict into its artifact. The harness reports the whole pipeline's status and swallows a trailing echo, so a failed run is reported as exit code 0. Write the verdict into the artifact you are going to read:
  { <verdict-bearing command>; echo \"EXIT=\$?\"; } > /tmp/check.log 2>&1"
  fi
  return 0
}

# A heredoc body is DATA the command is fed, not commands to run: a commit
# message, a config file, a JSON payload. Screening it is the same category
# error as screening markdown prose, and it is not hypothetical — the first live
# invocation of the deny hook refused a `git commit -F -` whose message text
# quoted `git commit ... 2>&1 | tail -N` while explaining that very defect. The
# body is dropped before any screen sees it; the line carrying the `<<` operator
# is kept, because that line holds the actual command.
strip_heredocs() {
  awk '
    BEGIN { in_h = 0; delim = ""; dash = 0 }
    {
      if (in_h) {
        line = $0
        if (dash) sub(/^[ \t]+/, "", line)
        if (line == delim) in_h = 0
        next
      }
      if (match($0, /<<-?[ \t]*["'\'']?[A-Za-z_][A-Za-z0-9_]*["'\'']?/)) {
        tok = substr($0, RSTART, RLENGTH)
        dash = (tok ~ /^<<-/)
        sub(/^<<-?[ \t]*/, "", tok)
        gsub(/["'\'']/, "", tok)
        delim = tok
        in_h = 1
      }
      print
    }
  ' <<<"$1"
}

# Screens a whole command string. 0 = a screen matched (REASON set), 1 = clean.
# $2 = 1 forces the backgrounded reading, for a harness that backgrounds the
# command out-of-band (Claude Code's run_in_background) rather than with a `&`.
screen_command() {
  local cmd forced_bg=${2:-0} seg trimmed
  # The same escape the files use, at command level: a deliberate demonstration
  # of a bad idiom carries the marker as a trailing comment and is let through.
  [[ $1 == *"$MARKER"* ]] && return 1

  # Fast path, and it is sound rather than a heuristic: f1 cannot match without
  # the literal word tail or head somewhere, and f3 cannot match unless the
  # command is backgrounded. Anything with neither is clean by construction.
  # This exists because the screens fork awk twice per command, and --scan over
  # a few thousand corpus lines was spending minutes on lines that could never
  # match. Widening a screen means revisiting this filter in the same edit.
  if [[ $forced_bg -eq 0 && $1 != *tail* && $1 != *head* && ! $1 =~ \&[[:space:]]*$ ]]; then
    return 1
  fi

  cmd=$1
  [[ $cmd == *'<<'* ]] && cmd=$(strip_heredocs "$cmd")
  trimmed=$(trim "$cmd")

  # f3 reads the RAW text: the sanctioned form's verdict lives inside
  # `echo "EXIT=$?"`, so dequoting here would blank the very thing it looks for
  # and deny the correct idiom.
  if [[ $forced_bg -eq 1 || $trimmed =~ (^|[^&])\&$ ]]; then
    REASON=""
    if screen_background "$trimmed"; then return 0; fi
  fi

  # f1 reads the DEQUOTED text, and dequoting happens before splitting: a `;`
  # inside a quoted argument is not a command separator, and splitting first
  # tears the quote in half, leaving the tail end of a string literal looking
  # like a bare command. That mis-split is what made this screen fire on its own
  # test file's `denies "..." 'echo "x" ; npm test | tail -5'`.
  while IFS= read -r seg; do
    if screen_segment "$seg"; then return 0; fi
  done < <(split_segments "$(dequote "$cmd")")
  return 1
}

# --- single-command mode -----------------------------------------------------
check_one() {
  local cmd=$1 forced_bg=${2:-0}
  [[ -n $(trim "$cmd") ]] || { echo "cannot decide: empty command" >&2; return 2; }
  if screen_command "$cmd" "$forced_bg"; then
    printf 'signal hygiene: %s\n' "$REASON"
    return 1
  fi
  return 0
}

# --- scan mode ---------------------------------------------------------------
# Emits `file:line: <reason first line>` per hit. Shell files are read directly,
# comments skipped. Markdown files read fenced shell blocks ONLY — that is where
# a skill's instructed commands live. Inline backtick spans and unfenced prose
# are never read: prose about a command is not an instruction to run it, and
# reading it would fire on every document that teaches the rule.
report_hit() { printf '%s:%s: %s\n' "$1" "$2" "${REASON%%$'\n'*}"; }

scan_shell() {
  local file=$1 hits=0 line n=0 marked=0 hd_delim="" hd_dash=0 probe
  local -a lines=()
  mapfile -t lines < "$file"
  for line in "${lines[@]}"; do
    n=$((n + 1))

    # A heredoc body is data the script feeds a command — a fixture, a config, a
    # commit message — not lines the shell will execute. Tracked here because
    # this scanner reads line by line and so cannot see what strip_heredocs sees
    # in a single command string. Without it, every seeded fixture in this
    # tool's own test file read as a live defect.
    if [[ -n $hd_delim ]]; then
      probe=$line
      [[ $hd_dash -eq 1 ]] && probe=${probe#"${probe%%[![:space:]]*}"}
      [[ $probe == "$hd_delim" ]] && hd_delim=""
      continue
    fi
    if [[ $line =~ \<\<(-?)[[:space:]]*[\"\']?([A-Za-z_][A-Za-z0-9_]*)[\"\']? ]]; then
      hd_dash=0
      [[ ${BASH_REMATCH[1]} == "-" ]] && hd_dash=1
      hd_delim=${BASH_REMATCH[2]}
    fi

    # The marker suppresses its own line (trailing comment) and the next
    # command line (comment above), which covers both ways people write it.
    if [[ $line == *"$MARKER"* ]]; then marked=1; continue; fi
    if [[ $(trim "$line") == \#* ]]; then continue; fi
    if [[ $marked -eq 1 ]]; then marked=0; continue; fi
    if screen_command "$line"; then
      report_hit "$file" "$n"
      hits=$((hits + 1))
    fi
  done
  [[ $hits -eq 0 ]]
}

scan_markdown() {
  local file=$1 hits=0 line n=0 armed=0 lang="" in_fence=0 skip_body=0 cmd
  local -a lines=()
  mapfile -t lines < "$file"
  for line in "${lines[@]}"; do
    n=$((n + 1))
    if [[ $in_fence -eq 0 ]]; then
      if [[ $line == *"$MARKER"* ]]; then armed=1; continue; fi
      if [[ $line =~ ^[[:space:]]*(\`\`\`|~~~)[[:space:]]*([A-Za-z0-9_+-]*) ]]; then
        lang=${BASH_REMATCH[2],,}
        in_fence=1
        case $lang in
          bash|sh|shell|zsh|console|shell-session) skip_body=$armed ;;
          *) skip_body=1 ;;   # not a shell fence — its body is not commands
        esac
        armed=0
      fi
      continue
    fi
    if [[ $line =~ ^[[:space:]]*(\`\`\`|~~~)[[:space:]]*$ ]]; then in_fence=0; continue; fi
    [[ $skip_body -eq 0 ]] || continue
    # console blocks prefix commands with `$ `; every other line is output.
    cmd=$line
    if [[ $lang == console || $lang == shell-session ]]; then
      [[ $cmd =~ ^[[:space:]]*\$[[:space:]] ]] || continue
      cmd=${cmd#*\$ }
    fi
    if [[ $(trim "$cmd") == \#* ]]; then continue; fi
    if screen_command "$cmd"; then
      report_hit "$file" "$n"
      hits=$((hits + 1))
    fi
  done
  [[ $hits -eq 0 ]]
}

scan_file() {
  local file=$1
  if [[ ! -r $file ]]; then
    echo "cannot decide: unreadable file: $file" >&2
    return 2
  fi
  case $file in
    *.md|*.markdown) scan_markdown "$file" ;;
    *)              scan_shell "$file" ;;
  esac
}

main() {
  local f rc any_deny=0 any_undecided=0
  if [[ ${1:-} == --scan ]]; then
    shift
    if [[ $# -eq 0 ]]; then echo "usage: $0 --scan <file> ..." >&2; return 2; fi
    for f in "$@"; do
      set +e; scan_file "$f"; rc=$?; set -e
      case $rc in
        1) any_deny=1 ;;
        2) any_undecided=1 ;;
      esac
    done
    # A real hit outranks an unreadable file: 1 is actionable, 2 only says the
    # scan could not look. Reporting 2 over a known defect would hide it.
    if [[ $any_deny -eq 1 ]]; then return 1; fi
    if [[ $any_undecided -eq 1 ]]; then return 2; fi
    return 0
  fi
  local forced_bg=0
  if [[ ${1:-} == --background ]]; then forced_bg=1; shift; fi
  if [[ $# -ne 1 ]]; then
    echo "usage: $0 [--background] '<command>' | $0 --scan <file> ..." >&2
    return 2
  fi
  check_one "$1" "$forced_bg"
}

main "$@"
