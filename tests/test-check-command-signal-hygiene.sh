#!/usr/bin/env bash
# Tests for Tools/check-command-signal-hygiene.sh — the two-screen predicate the
# signal-hygiene deny hook and the --scan lint both run.
#
# Every assertion about a screen is PAIRED, in the form
# hq's tests/verify-signal-hygiene.sh established: the shipped screen is shown
# catching the defect, AND a naive screen is shown false-passing (or
# false-firing) on the same input. A test that only checks the fix cannot tell
# you whether it still exercises the bug.
#
# The three naive screens below are not invented for the test. All are mistakes
# that were actually made while building this script:
#
#   NAIVE_BOUNDARY — the first draft anchored command names on whitespace, so
#     `$(git push ... | tail -2)` did not match: the character before `git` is
#     `(`. It reported hq's corpus clean while hq's own regression test held that
#     exact idiom. The screen false-passed on the defect it exists to detect,
#     which is the pattern this whole task is about, reproduced inside its fix.
#
#   NAIVE_WORD — screening on the word `tail` rather than on the PIPE. This
#     fires on the sanctioned redirect-then-read form, which ends in `tail`.
#     A screen that denies the correct idiom is worse than none: it teaches the
#     wrong lesson every time it fires.
#
#   NAIVE_ANYWHERE — the fix for NAIVE_BOUNDARY matched command names anywhere
#     after a non-word character, so a script NAME given as an argument read as
#     a run: `grep -n x tests/verify-a.sh | head` was denied. Every one of the
#     30 denials in hq's pilot review was a false alarm of this kind.
#
# The corpus assertion is what holds the screens narrow over time. It asserts
# ZERO hits across this repository's own tracked shell scripts and the standing rules —
# documents that quote the bad forms on purpose. If a future screen starts
# firing there, it is over-firing, and that is a failure here rather than an
# opinion in review.
# Every command string below is a LITERAL under test, not something this script
# runs. `$?`, `$(...)` and backticks inside them must reach the predicate
# unexpanded — expanding them would test a different string than the one named.
# shellcheck disable=SC2016
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$WORKSHOP_ROOT/Tools/check-command-signal-hygiene.sh"
SANCTIONED='bash tests/run-tests.sh > /tmp/check.log 2>&1; echo "EXIT=$?"; tail -40 /tmp/check.log'

PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
hr()  { printf '\n=========== %s\n' "$1"; }

[ -r "$CHECK" ] || { echo "PRECONDITION FAILED: $CHECK not readable" >&2; exit 1; }

rc_of() { set +e; bash "$CHECK" "$@" >/dev/null 2>&1; local r=$?; set -e; printf '%s' "$r"; }

denies() { # <description> <args...>
  local desc=$1; shift
  local r; r=$(rc_of "$@")
  if [ "$r" = 1 ]; then ok "denied: $desc"; else bad "expected deny (1), got $r: $desc"; fi
}
allows() { # <description> <args...>
  local desc=$1; shift
  local r; r=$(rc_of "$@")
  if [ "$r" = 0 ]; then ok "allowed: $desc"; else bad "expected clean (0), got $r: $desc"; fi
}
# is <actual> <expected> <ok message> <failure message>
is() {
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$4 (got $1, expected $2)"; fi
}

# --- 1. the f1 screen: verdict-bearing output piped into tail/head -----------
hr "1 — f1: verdict-bearing output piped into tail/head"
denies "test runner into tail"          'bash tests/run-tests.sh | tail -40'
denies "test runner into tail, 2>&1"    'bash tests/run-tests.sh 2>&1 | tail -40'
denies "npm test into head"             'npm test | head -20'
denies "pytest into bare tail"          'pytest -q | tail'
denies "git commit into tail"           'git commit -m "x" 2>&1 | tail -5'
denies "inside command substitution"    'OLD=$(git push -q origin main 2>&1 | tail -2)'
denies "inside backticks"               'OUT=`npm test | tail -5`'
denies "verify-*.sh into tail"          'bash tests/verify-thing.sh | tail -1'
denies "through an intermediate stage"  'npm test | grep -i error | tail -5'
# Command position reaches through what can stand in front of a run.
denies "executed script, path prefix"   './tests/verify-x.sh | head'
denies "make test into tail"            'make test | tail'
denies "pytest into tail -5"            'pytest | tail -5'
denies "under timeout and an interpreter" 'timeout 600 bash tests/run-tests.sh | tail'
denies "interpreter with options"       'bash -x tests/verify-a.sh | head'
denies "inside a subshell"              '( make test ) | tail'
denies "after cd &&"                    'cd sub && make check | tail'
denies "behind env and assignments"     'env CI=1 npm test | tail'
denies "behind a bare assignment"       'CI=1 pytest | tail'
denies "behind time"                    'time make test | tail'
denies "through a package runner"       'uv run pytest | tail'
denies "through python -m"              'python3 -m pytest -q | tail'
denies "through npx"                    'npx jest | tail'
denies "a pnpm-run binary"              'pnpm tsc | tail'
denies "by path into a venv"            '.venv/bin/pytest -q | tail'
denies "inside a mid-command substitution" 'echo $(npm test | tail -1)'
# Decision on finalization: echoing PIPESTATUS keeps the status but tail still
# discards the output the standing rule requires.
denies "PIPESTATUS still trims the output" 'git push origin b 2>&1 | tail -3; echo "push exit=${PIPESTATUS[0]}"'

diagnostic=$(bash "$CHECK" 'bash tests/run-tests.sh | tail -40' 2>&1 || true)
if [[ $diagnostic == *"verdict-bearing command"* ]]; then
  ok "diagnostic names a verdict-bearing command"
else
  bad "diagnostic does not use the semantic verdict-bearing label"
fi
if [[ $diagnostic != *"gate-ish"* ]]; then
  ok "diagnostic does not call an ordinary check gate-ish"
else
  bad "diagnostic still teaches the gate-ish label"
fi

# --- 2. the f3 screen: backgrounded with no verdict in the artifact ----------
hr "2 — f3: backgrounded verdict-bearing run with no in-artifact verdict"
denies "backgrounded, no verdict at all" 'bash tests/verify-thing.sh > out.txt 2>&1 &'
denies "verdict outside the braces"      'bash tests/run-tests.sh > out.txt 2>&1; echo "EXIT=$?" &'
denies "harness-backgrounded, unbraced"  --background 'bash tests/run-tests.sh > out.txt 2>&1; echo "EXIT=$?"'
denies "harness-backgrounded, no verdict" --background 'npm run build > b.log 2>&1'
denies "backgrounded after cd &&"        'cd sub && npm test > o.log 2>&1 &'
allows "a backgrounded search is not a run" 'grep -rn pytest . > hits.txt &'

# --- 3. what must never fire ------------------------------------------------
hr "3 — the sanctioned form and ordinary recall stay clean"
allows "THE sanctioned redirect-then-read form" "$SANCTIONED"
allows "braced verdict, backgrounded"      '{ bash tests/run-tests.sh; echo "EXIT=$?"; } > out.txt 2>&1 &'
allows "braced verdict, harness-backgrounded" --background '{ npm test; echo "EXIT=$?"; } > out.txt 2>&1'
allows "git log into head (recall)"        'git log --oneline | head -5'
allows "git status into head (recall)"     'git status --short | head -20'
allows "cat into tail (recall)"            'cat notes.txt | tail -3'
allows "ls into head (recall)"             'ls -la | head'
allows "find into head (recall)"           'find . -name "*.sh" | head -20'
allows "recall inside substitution"        'X=$(git log --oneline | head -1)'
allows "a check run plainly"               'bash tests/run-tests.sh'
allows "a commit with no pipe"             'git commit -m "wip" && git push'
# Reading a test script is not running it. Each of these was denied in hq's
# pilot review, when the pattern matched a script name in argument position.
allows "grep over a verify script"         'grep -n x tests/verify-a.sh | head'
allows "cat of a test script"              'cat tests/test-audit-tracker.sh | head -30'
allows "sed over a verify script"          'sed -n 1,60p tests/verify-cloud-token-scope.sh | head'
allows "git log over a verify script"      'git log --oneline a..HEAD -- tests/verify-command-signal-hygiene-corpus.sh | head -30'
allows "grep for a runner name"            'grep -n pytest notes.txt | head'
allows "installing a runner is not running it" 'npm install jest | tail'

# --- 4. the exit-2 contract -------------------------------------------------
hr "4 — cannot-decide is 2, never 0 by accident"
r=$(rc_of '')
is "$r" 2 "empty command -> 2" "empty command"
r=$(rc_of --scan "$WORKSHOP_ROOT/does-not-exist.sh")
is "$r" 2 "unreadable file -> 2" "unreadable file"

# --- 5. PAIRED: the naive whitespace boundary false-passes ------------------
# This is the mistake the first draft shipped. Both screens see the same string;
# the naive one reports it clean.
hr "5 — PAIRED: whitespace-anchored names miss \$(git push ... | tail)"
SUBST_DEFECT='OLD=$(git push -q origin main 2>&1 | tail -2)'
NAIVE_BOUNDARY='(^|[[:space:]])git[[:space:]]+(commit|push)([[:space:]]|$)'
naive_stage1=${SUBST_DEFECT%%|*}
if [[ $naive_stage1 =~ $NAIVE_BOUNDARY ]]; then
  bad "the naive boundary matched — this test no longer exercises the bug, repair it"
else
  ok "the naive whitespace boundary reports the piped push CLEAN (the false pass)"
fi
denies "the shipped screen catches it" "$SUBST_DEFECT"

# --- 6. PAIRED: screening on the word `tail` false-fires -------------------
# The sanctioned form ends in `tail`. A screen that looks for the word instead
# of the pipe denies the very idiom the standing rules prescribe.
hr "6 — PAIRED: word-matching \`tail\` denies the sanctioned form"
if [[ $SANCTIONED =~ (tail|head) ]]; then
  ok "the naive word screen fires on the sanctioned form (the false positive)"
else
  bad "the sanctioned form no longer contains 'tail' — this test is decorative, repair it"
fi
allows "the shipped screen leaves the sanctioned form alone" "$SANCTIONED"

# --- 10. PAIRED: matching anywhere reads a script name as a run ---------------
# The anywhere-matching boundary that fixed section 5 then fired on every read of
# a test script: in hq's pilot, all 30 of 872 commands it denied were false
# alarms. Frozen here as it shipped, script-name alternative only.
hr "10 — PAIRED: an anywhere match denies reading a test script"
READ_NOT_RUN='grep -n x tests/verify-a.sh | head'
NAIVE_ANYWHERE='(^|[^A-Za-z0-9_-])(run-tests|verify-[A-Za-z0-9_.-]+|test-[A-Za-z0-9_.-]+|check-[A-Za-z0-9_.-]+)\.sh([^A-Za-z0-9_-]|$)'
naive_stage1=${READ_NOT_RUN%%|*}
if [[ $naive_stage1 =~ $NAIVE_ANYWHERE ]]; then
  ok "the naive anywhere match fires on a grep over the script (the false positive)"
else
  bad "the naive anywhere match no longer fires — this test is decorative, repair it"
fi
allows "the shipped screen leaves the read alone" "$READ_NOT_RUN"

# --- 7. --scan over markdown: fenced shell blocks only ---------------------
hr "7 — --scan reads fenced shell blocks, honours the counter-example marker"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/seeded.md" <<'MD'
# Seeded

```bash
bash tests/run-tests.sh | tail -40
```
MD
r=$(rc_of --scan "$TMP/seeded.md")
is "$r" 1 "a seeded defect in a bash fence is caught" "seeded markdown defect"

cat > "$TMP/clean.md" <<'MD'
# Clean

The sanctioned form:

```bash
bash tests/run-tests.sh > /tmp/check.log 2>&1; echo "EXIT=$?"; tail -40 /tmp/check.log
```

A deliberate counter-example, marked:

<!-- signal-hygiene: counter-example -->
```bash
npm test | tail -5
```

Not a shell fence, so not commands:

```python
bash tests/run-tests.sh | tail -40
```

Prose naming the bad idiom — `npm test | tail -5` — is not an instruction.
MD
r=$(rc_of --scan "$TMP/clean.md")
is "$r" 0 "sanctioned form, marked block, non-shell fence and prose all stay clean" "clean markdown"

# Positive control: prove the marker is what silenced the block above, and not
# the scanner failing to read fences at all. Same file, marker removed.
grep -v 'signal-hygiene: counter-example' "$TMP/clean.md" > "$TMP/unmarked.md"
r=$(rc_of --scan "$TMP/unmarked.md")
is "$r" 1 "removing the marker makes the same block fire — the marker is load-bearing" \
   "unmarked counter-example; the fence scanner may not be reading at all"

cat > "$TMP/seeded.sh" <<'SH'
#!/usr/bin/env bash
# a comment mentioning npm test | tail -5 is not a command
bash tests/run-tests.sh | tail -40
SH
r=$(rc_of --scan "$TMP/seeded.sh")
is "$r" 1 "a seeded defect in a shell script is caught, comments ignored" "seeded shell defect"

cat > "$TMP/marked.sh" <<'SH'
#!/usr/bin/env bash
# signal-hygiene: counter-example
bash tests/run-tests.sh | tail -40
SH
r=$(rc_of --scan "$TMP/marked.sh")
is "$r" 0 "the shell marker suppresses the next command line" "marked shell counter-example"

# --- 9. data is not a command -----------------------------------------------
# Every case here was found by the hook denying a real command during its own
# construction. A quoted argument, a heredoc body and a commit message are data
# the command is handed, not commands that will run; screening them denies the
# people documenting, testing or fixing the very defect. The direction of the
# error matters: under-firing on `bash -c "<idiom>"` costs one missed case,
# over-firing on every mention of it makes the tree unusable.
hr "9 — quoted arguments, heredoc bodies and marked commands are data"
allows "idiom as a single-quoted argument"  "probe 'npm test | tail -5' 'desc'"
allows "idiom as a double-quoted argument"  'echo "npm test | tail -5"'
allows "idiom as a grep pattern"            'grep -rn "npm test | tail" .'
allows "command-level counter-example marker" 'npm test | tail -5   # signal-hygiene: counter-example'
# Written as $'...' one-liners rather than multi-line literals on purpose: this
# file is itself in the corpus scanned by assertion 8, and a line-by-line
# scanner cannot tell a line inside a multi-line string literal from a command.
# Keeping each fixture on one line lets dequoting do the work.
HEREDOC_MSG=$'git commit -F - <<EOF\na commit message about git commit 2>&1 | tail -5\nEOF'
allows "idiom inside a heredoc body" "$HEREDOC_MSG"
# ...and the stripping must not swallow what follows the heredoc.
HEREDOC_THEN_DEFECT=$'git commit -F - <<EOF\nmsg\nEOF\nnpm test | tail -5'
denies "a real defect after a heredoc" "$HEREDOC_THEN_DEFECT"
denies "a real defect after a quoted argument" 'echo "harmless" ; npm test | tail -5'

# --- 8. corpus: the screens do not fire on this repo's own tracked files ---
# Over-firing is a checked property, not an opinion. The standing rules quote the
# bad forms; the scripts use the good ones. Zero hits, or a screen is too broad.
#
# Skill bodies are in the corpus because that is where *instructed* commands
# live — an agent reads a SKILL.md fence and runs what it says, so a bad idiom
# there is an instruction to reproduce the defect. Prose records of a bad
# command (a kaizen journal entry describing what went wrong) are deliberately
# not in scope: those are records, not instructions.
hr "8 — corpus: zero hits across this repo's tracked scripts, skill bodies and standing rules"
mapfile -t corpus < <(git -C "$WORKSHOP_ROOT" ls-files '*.sh' '.agents/skills/*.md' '.agents/skills/**/*.md' 'docs/signal-hygiene.md' 'docs/definition-of-done.md')
if [ "${#corpus[@]}" -lt 10 ]; then
  echo "PRECONDITION FAILED: corpus is ${#corpus[@]} file(s) — the scan would pass vacuously" >&2
  exit 1
fi
cd "$WORKSHOP_ROOT"
set +e
corpus_out=$(bash "$CHECK" --scan "${corpus[@]}" 2>&1); corpus_rc=$?
set -e
if [ "$corpus_rc" = 0 ]; then
  ok "${#corpus[@]} tracked files scanned, 0 hits"
else
  bad "the screens fire on this repo's own corpus (rc=$corpus_rc) — too broad:"
  printf '%s\n' "$corpus_out" | sed 's/^/       /'
fi

hr "RESULT"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
