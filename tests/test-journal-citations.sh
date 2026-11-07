#!/usr/bin/env bash
# Exercise adopted journal citations with the unchanged strict Markdown checker.
# Fixture edits model the documented procedure, not an automated migration tool.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="$root/Tools/check-markdown-links.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name=test -c user.email=test@example.com commit -qm "$2"
}
run_check() {
  rc=0
  bash "$check" "$repo" > "$work/check.log" 2>&1 || rc=$?
}
expect_pass() {
  run_check
  [[ "$rc" -eq 0 ]] || { cat "$work/check.log"; fail "$1 exited $rc"; }
  grep -Fxq 'Markdown links valid; 0 source or target(s) skipped' "$work/check.log" \
    || { cat "$work/check.log"; fail "$1 did not check the complete fixture"; }
}
expect_broken() {
  run_check
  [[ "$rc" -eq 1 ]] || { cat "$work/check.log"; fail "$1 exited $rc, expected 1"; }
  grep -Fxq "broken Markdown link: $survivor -> $2" "$work/check.log" \
    || { cat "$work/check.log"; fail "$1 did not name the journal and missing target"; }
}

for kind in problem task pattern; do
  repo="$work/$kind"
  case "$kind" in
    problem) target='docs/work/problems/fixed.md'; destination='../../../problems/fixed.md' ;;
    task) target='docs/work/tasks/soon/fixed.md'; destination='../../../tasks/soon/fixed.md' ;;
    pattern) target='docs/work/kaizen/patterns/fixed.md'; destination='../../patterns/fixed.md' ;;
  esac
  journal='docs/work/kaizen/journal/2026-01'
  survivor="$journal/2026-01-02-survivor.md"
  evidence="$journal/2026-01-01-consumed.md"
  mkdir -p "$repo/$journal" "$repo/$(dirname "$target")"
  printf '# Fixed\n\nThe fixture retirement prerequisites have been met.\n' > "$repo/$target"
  printf '# Consumed evidence\n\nThe original observation remains relevant to the survivor.\n' > "$repo/$evidence"
  printf '# Survivor\n\nThe [known issue](%s) recurred.\nSee [original evidence](2026-01-01-consumed.md).\n' "$destination" > "$repo/$survivor"
  printf '# Index\n\n[Active record](%s)\n' "${target#docs/}" > "$repo/docs/index.md"
  if [[ "$kind" == problem ]]; then
    printf '\nEvidence: [original observation](../kaizen/journal/2026-01/2026-01-01-consumed.md)\n' >> "$repo/$target"
  fi
  git -C "$repo" init -q
  commit_all "$repo" legacy
  expect_pass "$kind initial links"

  # Old behavior: repairing editable references cannot repair an immutable journal.
  git -C "$repo" rm -q "$target"
  printf '# Index\n' > "$repo/docs/index.md"
  git -C "$repo" add docs/index.md
  expect_broken "$kind unmigrated retirement" "$destination"
  git -C "$repo" restore --source=HEAD --staged --worktree -- "$target" docs/index.md

  # Explicit one-time migration preserves the label, surrounding words and evidence.
  # shellcheck disable=SC2016 # Backticks are literal Markdown fixture content.
  printf '# Survivor\n\nThe known issue (%s `fixed`) recurred.\nSee [original evidence](2026-01-01-consumed.md).\n' "$kind" > "$repo/$survivor"
  expect_pass "$kind adoption"
  commit_all "$repo" 'Adopt slug citations as a one-time journal exception'
  cp "$repo/$survivor" "$work/$kind-survivor.before"
  cp "$repo/$evidence" "$work/$kind-evidence.before"

  git -C "$repo" rm -q "$target"
  printf '# Index\n' > "$repo/docs/index.md"
  git -C "$repo" add docs/index.md
  cmp "$repo/$survivor" "$work/$kind-survivor.before" || fail "$kind retirement changed survivor"
  cmp "$repo/$evidence" "$work/$kind-evidence.before" || fail "$kind retirement changed evidence"
  if [[ "$kind" == problem ]]; then
    receipt='docs/work/kaizen/pending-problem-reviews/fixed.md'
    mkdir -p "$repo/$(dirname "$receipt")"
    source_sha=$(git -C "$repo" rev-parse HEAD)
    cat > "$repo/$receipt" <<EOF
# Pending evidence review

Evidence from retired problem fixed awaits Kaizen review.

Former path: docs/work/problems/fixed.md
Source revision: $source_sha (retired copy unchanged).
Reason: the fixture's marker was verified corrected. Pending Kaizen review.

[Consumed evidence](../journal/2026-01/2026-01-01-consumed.md)
EOF
    git -C "$repo" add "$receipt"
    [[ "$(git -C "$repo" diff --cached --name-only | wc -l)" -eq 3 ]] \
      || fail 'retirement must stage exactly problem, index, receipt'
  fi
  expect_pass "$kind adopted retirement"

  # The surviving evidence link remains a real dependency, never a slug citation.
  git -C "$repo" rm -q "$evidence"
  expect_broken "$kind cited evidence deletion" '2026-01-01-consumed.md'
  git -C "$repo" restore --source=HEAD --staged --worktree -- "$evidence"
  expect_pass "$kind retained evidence"
  printf 'ok - %s: legacy deletion fails; adopted retirement preserves journals; cited evidence stays protected\n' "$kind"
done

# With no journal dependency, problem retirement creates no Kaizen directory.
repo="$work/no-kaizen"
mkdir -p "$repo/docs/work/problems"
git -C "$repo" init -q
printf '# Fixed problem\n\nThe fixture marker is corrected.\n' > "$repo/docs/work/problems/fixed.md"
commit_all "$repo" initial
git -C "$repo" rm -q docs/work/problems/fixed.md
expect_pass 'retirement without Kaizen'
[[ ! -e "$repo/docs/work/kaizen" ]] || fail 'unexpected Kaizen prerequisite'

# A receipt alone protects evidence even when no other artifact cites it.
repo="$work/problem"
survivor="docs/work/kaizen/journal/2026-01/2026-01-02-survivor.md"
evidence="docs/work/kaizen/journal/2026-01/2026-01-01-consumed.md"
# shellcheck disable=SC2016 # Literal Markdown citation.
printf '# Survivor\n\nHistorical problem `fixed` is retired.\n' > "$repo/$survivor"
expect_pass 'receipt holds otherwise unreferenced evidence'
git -C "$repo" rm -q "$evidence"
run_check
[[ "$rc" -eq 1 ]] || fail 'dangling pending receipt must fail'
grep -Fq "broken Markdown link: $receipt -> ../journal/2026-01/2026-01-01-consumed.md" "$work/check.log" \
  || fail 'checker did not identify pending evidence loss'
git -C "$repo" restore --source=HEAD --staged --worktree -- "$evidence"
# Model review retaining a useful lesson in the watchlist, then discharging receipt.
printf '# Watchlist\n\n[Consumed evidence](journal/2026-01/2026-01-01-consumed.md) — fixture lesson remains useful.\n' > "$repo/docs/work/kaizen/singletons.md"
rm "$repo/$receipt"
expect_pass 'review hands retained evidence to watchlist'
cmp "$repo/$evidence" "$work/problem-evidence.before" || fail 'review altered evidence'
echo 'all journal-citation fixtures passed'
