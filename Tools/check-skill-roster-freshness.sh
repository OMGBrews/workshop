#!/usr/bin/env bash
# check-skill-roster-freshness.sh — detect a mid-session change to a repo's
# skill ENTRY SET and print the reload/restart instruction.
#
# Why this exists: a running agent session snapshots its skill roster at start
# (Oh My Pi has no mid-session rescan at all; Claude Code's live-change
# detection watches paths and event kinds that the devtools symlink transition
# does not produce). A sync landing mid-session — a manual pull/rebase, or the
# propagation tooling's fast-forwards — changes the skill entry set
# (.claude/skills/* and .agents/skills/* names: additions, renames, removals)
# while the running roster keeps serving the old names, silently. This script
# is the seam that observes both routes: it runs as a git
# post-merge/post-checkout/post-rewrite hook (Tools/hooks/, wired through
# core.hooksPath), so every tree-changing git operation in a consumer repo
# passes through it. Full investigation and per-harness trials:
# docs/harness-verification-log.md.
#
# What it compares: entry NAMES only, not file content. A skill is addressed
# by its directory name, and SKILL.md bodies are read at invocation time, so a
# content change behind an unchanged name does not stale a roster; a rename,
# addition, or removal does.
#
# Commands (first argument):
#   baseline  Record the current entry set as the session-start baseline.
#             Called by the session bootstrap (the agent-session-start.sh
#             template) once per session, after it has settled the tree.
#   check     Compare the current entry set against the baseline and print
#             the reload instruction when they differ; the default (hook mode).
#   print     Print the current fingerprint. Used by Tools/sync-skill-symlinks.sh
#             to compare before/after its own run without duplicating the
#             fingerprint definition.
#
# State files, both under the repo's git dir (never committed):
#   skills-roster-baseline  written at session start when the bootstrap is
#                           wired in; the hook's preferred comparison point
#   skills-roster-last      the state recorded after the previous check —
#                           the fallback comparison when no session-start
#                           baseline exists (a session that never ran the
#                           bootstrap, or a plain terminal). Coarser ("since
#                           the last git operation") but still catches every
#                           mid-session change except the very first
#                           tree-changing operation, which has no prior state
#                           to compare against. The wired path has no such gap.
#
# Exit 0 always: this is a warning seam, and nothing here should fail a git
# operation (post-* hook exit codes are ignored by git anyway).
set -u

COMMAND="${1:-check}"

gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
BASELINE="$gitdir/skills-roster-baseline"
LAST="$gitdir/skills-roster-last"

# The sorted entry names per skill surface. Both surfaces, because a harness
# may read either: Claude Code reads .claude/skills, other harnesses read
# .agents/skills, and the transition moves or retargets names between them.
# Dangling links count as entries — a dangling name is itself a
# roster-relevant state — so -L is tested first and stands alone.
#
# Skills only: a skill is a directory, so a plain file on either surface is not
# a roster entry. The generated .claude/skills/README.md is the one this fleet
# writes, and counting it would announce a stale roster — sending the operator
# to /reload-skills — on the sync that merely dropped a signpost in, with no
# skill name changed at all.
fingerprint() {
  (
    cd "$repo_root" || return 1
    for d in .claude/skills .agents/skills; do
      if [ -d "$d" ]; then
        printf '%s:' "$d"
        for e in "$d"/*; do
          { [ -L "$e" ] || [ -d "$e" ]; } && printf ' %s' "${e##*/}"
        done
        printf '\n'
      fi
    done
  ) | LC_ALL=C sort
}

# <old> <new> — added and removed entries, one per line, +/- prefixed, at
# skill-name granularity (surface-prefixed), so a rename names its subjects.
diff_entries() {
  tokens() { printf '%s\n' "$1" | awk '{ s = $1; for (i = 2; i <= NF; i++) print s, $i }'; }
  comm -13 <(tokens "$1") <(tokens "$2") | sed 's/^/+ /'
  comm -23 <(tokens "$1") <(tokens "$2") | sed 's/^/- /'
}

# The reload instruction, harness-appropriate when the harness is identifiable
# from the tool environment, the honest full list when it is not. Claude Code
# exports CLAUDE_CODE_ENTRYPOINT in its tool environment; Codex exports
# CODEX_HOME; Oh My Pi exports nothing reliably distinguishable, so the generic
# line carries its command too.
harness_hint() {
  if [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]; then
    printf 'Run /reload-skills in this session to rebuild the skill roster.\n'
  elif [ -n "${CODEX_HOME:-}" ]; then
    printf 'Codex refreshes its skill roster automatically; no action needed.\n'
  else
    printf 'If an agent session is running in this repo, its skill roster is stale: run /reload-skills (Claude Code) or /reload (Oh My Pi). Codex refreshes automatically.\n'
  fi
}

record_state() { # <file>
  printf '%s\n' "$now" > "$1"
}

now="$(fingerprint)" || exit 0

case "$COMMAND" in
  baseline)
    record_state "$BASELINE"
    record_state "$LAST"
    ;;
  check)
    if [ -f "$BASELINE" ]; then
      prev="$(cat "$BASELINE")"
      if [ "$now" != "$prev" ]; then
        printf 'SKILL ROSTER CHANGED since this session started — the running session is serving stale skill names.\n'
        diff_entries "$prev" "$now"
        harness_hint
        # Rebaseline: one warning per change, silence after recovery, and a
        # second mid-session change warns again.
        record_state "$BASELINE"
      fi
      record_state "$LAST"
    elif [ -f "$LAST" ]; then
      prev="$(cat "$LAST")"
      if [ "$now" != "$prev" ]; then
        printf 'SKILL ROSTER CHANGED since the last git operation in this repo.\n'
        diff_entries "$prev" "$now"
        harness_hint
      fi
      record_state "$LAST"
    else
      # First tree-changing operation ever observed in this repo: record the
      # state silently. Nothing earlier exists to compare against, and the
      # wired (bootstrap) path has already recorded a baseline by this point.
      record_state "$LAST"
    fi
    ;;
  print)
    printf '%s\n' "$now"
    ;;
esac
exit 0
