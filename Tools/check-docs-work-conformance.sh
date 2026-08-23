#!/usr/bin/env bash
# check-docs-work-conformance.sh — does this repo's docs/work/ directory conform
# to the fleet docs work-directory contract?
#
# The fleet is consolidating the files the devtools machine reads and writes
# into one machine-owned directory, docs/work/, inside every repository. The
# contract that specifies the layout is private — deliberately not published to
# the workshop mirror — so this script encodes the clause matrix directly
# in the clearly labelled sections below and never reads the contract at
# runtime; consumers receive the contract's decisions through their migration
# briefs. Runtime output therefore never requires a private document to be
# present in the consuming checkout.
#
# One line per registry clause, with four stable verdicts:
#   ok     — the clause's enforceable assertions all hold
#   FAIL   — an enforceable assertion is violated; the line names the clause,
#            the offending artifact, and the expected correction
#   absent — the clause does not apply (an opt-in subsystem not opted in, a
#            declaration not made)
#   note   — a clause reported without pretending a mechanical assertion ran
#            (a declaration owned by another tool, an audited-only row outside
#            this contract's jurisdiction)
#
# Usage: bash Tools/check-docs-work-conformance.sh <repo-root>
# The repo-root argument is REQUIRED and must be the root of a Git worktree: a
# default would silently audit the wrong tree, and the handoff clause depends
# on tracked-file identity.
# Exit 0 -> every enforceable clause conforms.  Exit 1 -> at least one clause
# failed; every failure is named on stdout.  Exit 2 -> usage error (argument
# missing, not enterable, or not a Git worktree root). The text, not the
# number, is the diagnostic interface.
#
# Every assertion states a POSITIVE property of an artifact, per
# devtools/docs/signal-hygiene.md: run it against a repo where none of this
# work was done and it goes red, not green.
# devtools/tests/test-check-docs-work-conformance.sh builds a conforming repo
# and an unmigrated one and pins both outcomes.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: bash Tools/check-docs-work-conformance.sh <repo-root>" >&2
    echo "  one repo-root argument is required — a default would silently audit the wrong tree" >&2
    exit 2
fi
root="$1"
cd "$root" || { echo "cannot enter '$root'" >&2; exit 2; }
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "not a Git worktree: '$root' — the handoff clause depends on tracked-file identity" >&2
    exit 2
fi
if [ "$(git rev-parse --show-toplevel)" != "$(pwd -P)" ]; then
    echo "not the Git worktree root: '$root' — pass the repo root, not a subdirectory" >&2
    exit 2
fi

devtools_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readiness_checker="$devtools_root/.agents/skills/task-finalize/check-task-readiness.sh"
if [ ! -f "$readiness_checker" ]; then
    echo "missing bundled task readiness checker: '$readiness_checker'" >&2
    exit 2
fi

failures=0
notes=0

pass()   { printf 'ok   %-2s %s\n' "$1" "$2"; }
fail()   { printf 'FAIL %-2s %s\n' "$1" "$2"; failures=$((failures + 1)); }
absent() { printf 'absent %-2s %s\n' "$1" "$2"; }
note()   { printf 'note  %-2s %s\n' "$1" "$2"; notes=$((notes + 1)); }


# Validate one ordinary task brief through task-finalize's shared parser.
# It deliberately does not ask for the full handoff verdict: human-bucket
# drafts may have open questions and no finalized-at stamp.  The command runs
# under set -e, so capture exit 1 explicitly and let clause 11 aggregate every
# malformed brief into its stable FAIL record.
#   $1 = brief path, $2 = human or queued finalized-at policy.
validate_brief() {
    local out rc=0
    out=$(bash "$readiness_checker" --conformance "$1" "$2") || rc=$?
    if [ "$rc" -eq 2 ]; then
        printf 'readiness checker could not inspect this brief: %s\n' "$out"
    elif [ -n "$out" ]; then
        printf '%s\n' "$out"
    elif [ "$rc" -ne 0 ]; then
        printf 'readiness checker failed with exit %s without a format verdict\n' "$rc"
    fi
    return 0
}

echo "== docs/work conformance: $root"

# --- 1: the task tree (required for repos on the task system) ----------------
# Detected by the target tree or a legacy tasks root — docs/tasks/ and
# docs/planning/tasks/, the same two-path resolution every task skill does.
tasks_active=0
[ -d docs/work/tasks ] && tasks_active=1
[ -d docs/tasks ] && tasks_active=1
[ -d docs/planning/tasks ] && tasks_active=1

if [ "$tasks_active" -eq 0 ]; then
    absent 1 "no task system — neither docs/work/tasks/ nor a legacy tasks root exists"
else
    problems=""
    if [ ! -d docs/work/tasks ]; then
        problems="${problems}docs/work/tasks/ does not exist — migrate the tasks tree to the machine-owned location; "
    fi
    for b in now soon later never; do
        if [ ! -d "docs/work/tasks/$b" ]; then
            problems="${problems}missing human bucket docs/work/tasks/$b/; "
        fi
    done
    for legacy in docs/tasks docs/planning/tasks; do
        if [ -d "$legacy" ]; then
            problems="${problems}legacy tasks root $legacy/ remains — delete it once the migration lands; "
        fi
    done
    if [ -d docs/work/tasks/done ] || [ -d docs/tasks/done ] || [ -d docs/planning/tasks/done ]; then
        problems="${problems}done/ bucket present — completed tasks are deleted, never archived to done/; "
    fi
    if [ -n "$problems" ]; then
        fail 1 "$problems"
    else
        pass 1 "docs/work/tasks/ with now/ soon/ later/ never/ buckets; no legacy root, no done/ bucket"
    fi
fi

# --- 2: kaizen (opt-in; location-and-required-skeleton check) -----------------
# The skeleton the registry names: journal/ and patterns/ under the kaizen
# root. singletons.md is optional (a not-yet-created watchlist) and is not
# audited here.
if [ ! -d docs/work/kaizen ] && [ ! -d docs/kaizen ]; then
    absent 2 "no kaizen system (docs/work/kaizen/ and legacy docs/kaizen/ both absent)"
else
    problems=""
    if [ ! -d docs/work/kaizen ]; then
        problems="${problems}docs/work/kaizen/ does not exist — migrate the kaizen tree (journal/ + patterns/) to docs/work/kaizen/; "
    else
        if [ ! -d docs/work/kaizen/journal ]; then
            problems="${problems}missing docs/work/kaizen/journal/; "
        fi
        if [ ! -d docs/work/kaizen/patterns ]; then
            problems="${problems}missing docs/work/kaizen/patterns/; "
        fi
    fi
    if [ -d docs/kaizen ]; then
        problems="${problems}legacy kaizen root docs/kaizen/ remains — delete it once the migration lands; "
    fi
    if [ -n "$problems" ]; then
        fail 2 "$problems"
    else
        pass 2 "docs/work/kaizen/ with journal/ and patterns/; no legacy root"
    fi
fi

# --- 3: problem documents (opt-in, kaizen's output) ---------------------------
# The registry names the problems README as a required part of the collection.
# Legacy roots: docs/problems/ (the fleet default) and docs/planning/problems/
# (llmkit-dev's severity-bucket variant) — both must migrate.
if [ ! -d docs/work/problems ] && [ ! -d docs/problems ] && [ ! -d docs/planning/problems ]; then
    absent 3 "no problem documents (docs/work/problems/ and the legacy roots docs/problems/, docs/planning/problems/ all absent)"
else
    problems=""
    if [ ! -d docs/work/problems ]; then
        problems="${problems}docs/work/problems/ does not exist — migrate the problem documents to docs/work/problems/; "
    elif [ ! -f docs/work/problems/README.md ]; then
        problems="${problems}docs/work/problems/README.md is missing — the README is a required part of the problems collection; "
    fi
    if [ -d docs/problems ]; then
        problems="${problems}legacy problems root docs/problems/ remains — delete it once the migration lands; "
    fi
    if [ -d docs/planning/problems ]; then
        problems="${problems}legacy problems root docs/planning/problems/ remains — delete it once the migration lands; "
    fi
    if [ -n "$problems" ]; then
        fail 3 "$problems"
    else
        pass 3 "docs/work/problems/ with its README; no legacy root"
    fi
fi

# --- 4: the handoff outbox (the mailbox) --------------------------------------
# A handoff is any tracked file whose frontmatter carries handoff-to:; the
# sweep is content-keyed, so the clause activates on the signal as well as on
# either outbox location.
pending=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    if head -n 8 "$f" 2>/dev/null | grep -q '^handoff-to:'; then
        pending="${pending}${f} "
    fi
done < <(git ls-files '*.md')

if [ ! -d docs/work/handoffs ] && [ ! -d docs/planning/handoffs ] && [ -z "$pending" ]; then
    absent 4 "no handoff outbox (docs/work/handoffs/ and legacy docs/planning/handoffs/ both absent, no handoff-to: briefs)"
else
    problems=""
    if [ ! -d docs/work/handoffs ]; then
        problems="${problems}docs/work/handoffs/ does not exist — migrate the outbox to the machine-owned location; "
    fi
    if [ -d docs/planning/handoffs ]; then
        problems="${problems}legacy outbox docs/planning/handoffs/ remains — delete it once the migration lands; "
    fi
    if [ -n "$problems" ]; then
        fail 4 "$problems"
    else
        pass 4 "docs/work/handoffs/ present; no legacy outbox"
    fi
    if [ -n "$pending" ]; then
        note 4 "pending handoff brief(s): $pending — the sweep is content-keyed, so a brief may sit anywhere; this is a report, not a failure"
    fi
fi

# --- 5: the thought inbox (opt-in) --------------------------------------------
if [ ! -d docs/work/thoughts ] && [ ! -d docs/planning/thoughts ]; then
    absent 5 "no thought inbox (docs/work/thoughts/ and legacy docs/planning/thoughts/ both absent)"
else
    problems=""
    if [ ! -d docs/work/thoughts ]; then
        problems="${problems}docs/work/thoughts/ does not exist — migrate the thought inbox to the machine-owned location; "
    fi
    if [ -d docs/planning/thoughts ]; then
        problems="${problems}legacy inbox docs/planning/thoughts/ remains — delete it once the migration lands; "
    fi
    if [ -n "$problems" ]; then
        fail 5 "$problems"
    else
        pass 5 "docs/work/thoughts/ present; no legacy inbox"
    fi
fi

# --- 6: definition-of-done.md (universal) -------------------------------------
# The same positive bar hq's verify-definition-of-done.sh applies: a level-one
# heading plus substantive content. "The file exists" would pass on the shape
# a half-done rollout leaves behind.
if [ ! -f docs/work/definition-of-done.md ]; then
    fail 6 "docs/work/definition-of-done.md is missing — every repo names its gates here, and a repo with none owes the one line that says so"
else
    heading=$(grep -c '^# ' docs/work/definition-of-done.md || true)
    body=$(grep -cv '^[[:space:]]*$\|^#' docs/work/definition-of-done.md || true)
    if [ "$heading" -lt 1 ]; then
        fail 6 "docs/work/definition-of-done.md has no level-1 heading — this is not a written document"
    elif [ "$body" -lt 2 ]; then
        fail 6 "docs/work/definition-of-done.md is a heading and $body line(s) of content — it names no gate and does not say there are none"
    else
        pass 6 "docs/work/definition-of-done.md ($heading heading, $body content line(s))"
    fi
fi

# --- 7: DOCS-ONLY declaration (optional; owned by docs-only-diff.sh) ----------
# Reported, not re-validated: docs-only-diff.sh is the single definition of
# the predicate's syntax and diff semantics, and duplicating either here would
# let the two drift.
if [ ! -f docs/work/definition-of-done.md ]; then
    note 7 "cannot report a DOCS-ONLY declaration — docs/work/definition-of-done.md is missing (clause 6 owns that failure)"
elif grep -q '^<!-- DOCS-ONLY:BEGIN' docs/work/definition-of-done.md; then
    note 7 "DOCS-ONLY block present in docs/work/definition-of-done.md — its syntax and behavior are owned by Tools/docs-only-diff.sh"
else
    absent 7 "no DOCS-ONLY declaration — the docs-only fast lane is not declared"
fi

# --- 8: consumed-by.md (required where a parent mounts the repo) --------------
# A missing file in both locations means "no declared parents", never an
# error. When present, the new location is required and its first anchored
# CONSUMED-BY block is validated with /ship's own parser rules: sentinels
# anchored to the start of a line, stop at the first END, every declaration
# line either `fleet` or owner/repo.
if [ ! -f docs/work/consumed-by.md ] && [ ! -f docs/consumed-by.md ]; then
    note 8 "no declared parents — a missing consumed-by.md is not an error (unadopted repos degrade gracefully)"
else
    if [ ! -f docs/work/consumed-by.md ]; then
        fail 8 "consumed-by.md exists only at the legacy location docs/consumed-by.md — migrate it to docs/work/consumed-by.md"
    else
        decl=$(awk '/^<!-- CONSUMED-BY:END/{exit} p && NF; /^<!-- CONSUMED-BY:BEGIN/{p=1}' docs/work/consumed-by.md)
        if [ -z "$decl" ]; then
            fail 8 "docs/work/consumed-by.md has no CONSUMED-BY declaration between the sentinels — a mangled sentinel or an emptied block is a broken declaration, not 'no parents'"
        else
            bad=$(printf '%s\n' "$decl" | grep -Evx 'fleet|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' || true)
            if [ -n "$bad" ]; then
                fail 8 "docs/work/consumed-by.md declares a line /ship cannot read: $(printf '%s' "$bad" | tr '\n' ' ')— each line must be 'fleet' or owner/repo"
            else
                pass 8 "docs/work/consumed-by.md declares: $(printf '%s' "$decl" | tr '\n' ' ')"
            fi
        fi
    fi
    if [ -f docs/consumed-by.md ]; then
        fail 8 "legacy docs/consumed-by.md remains beside the migrated copy — delete it once the migration lands"
    fi
fi


# --- 9: focus.md (opt-in) -----------------------------------------------------
if [ "$tasks_active" -eq 0 ]; then
    absent 9 "no task system — no tasks root to hold a focus document"
elif [ -f docs/work/tasks/focus.md ] && [ -s docs/work/tasks/focus.md ]; then
    pass 9 "docs/work/tasks/focus.md present — its format is owned by task-reprioritize/ranking-rubric.md, not re-validated here"
elif [ -e docs/work/tasks/focus.md ]; then
    fail 9 "docs/work/tasks/focus.md is empty or unreadable — a focus document must state the owner's direction in prose"
else
    absent 9 "no focus document — ranking runs on mechanics alone"
fi

# --- 10: queued/README.md (required alongside the queue opt-in) ---------------
# The queue is an opt-in: its presence enables the autonomous runner, and the
# README is what keeps the empty directory alive in git.
if [ "$tasks_active" -eq 0 ]; then
    absent 10 "no task system — no queue to keep alive"
elif [ -d docs/work/tasks/queued ]; then
    if [ -f docs/work/tasks/queued/README.md ]; then
        pass 10 "docs/work/tasks/queued/README.md present — the queue directory is opted in and kept alive in git"
    else
        fail 10 "docs/work/tasks/queued/ exists but docs/work/tasks/queued/README.md is missing — the README is what keeps the empty queue directory alive in git"
    fi
else
    absent 10 "no queued/ directory — the autonomous runner is not opted in"
fi

# --- 11: the document-format contract (required for task documents) -----------
# Ordinary briefs in the four human buckets need the four author-required
# frontmatter values and the AC sentinels; finalized-at is not required there.
# Briefs in queued/ and queued/blocked/ additionally need a valid finalized-at
# commit, because queue admission already requires readiness. Reserved support
# documents (README.md, focus.md) and the runner's forensic
# markers (the .crashed / .merge-failed / .abandoned-wip / .dispatch-failed /
# .ci-stuck / .partial shapes the runner commits) are not briefs.
if [ "$tasks_active" -eq 0 ]; then
    absent 11 "no task system — no briefs to validate"
elif [ ! -d docs/work/tasks ]; then
    note 11 "cannot validate brief format — docs/work/tasks/ is missing (clause 1 owns that failure)"
else
    checked=0
    brief_problems=""
    while IFS= read -r bucket; do
        [ -n "$bucket" ] || continue
        [ -d "docs/work/tasks/$bucket" ] || continue
        policy="human"
        case "$bucket" in
            queued | queued/blocked) policy="queued" ;;
        esac
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            checked=$((checked + 1))
            v=$(validate_brief "$f" "$policy")
            if [ -n "$v" ]; then
                brief_problems="${brief_problems}${f}: $(printf '%s' "$v" | tr '\n' '; ')"
            fi
        done < <(find "docs/work/tasks/$bucket" -maxdepth 1 -type f -name '*.md' \
                     ! -name 'README.md' ! -name 'focus.md' \
                     ! -name '*.crashed.*.md' ! -name '*.merge-failed.*.md' \
                     ! -name '*.abandoned-wip.*.md' ! -name '*.dispatch-failed.*.md' \
                     ! -name '*.ci-stuck.*.md' ! -name '*.partial.*.md')
    done < <(printf 'now\nsoon\nlater\nnever\nqueued\nqueued/blocked\n')

    if [ -n "$brief_problems" ]; then
        fail 11 "$brief_problems"
    elif [ "$checked" -eq 0 ]; then
        pass 11 "no ordinary briefs to validate (the buckets hold only support documents)"
    else
        pass 11 "$checked brief(s) validated — four author-required frontmatter fields, AC sentinels, and finalized-at in the queue"
    fi
fi

# --- 12-15: audited-only rows (reported, not reimplemented) -------------------
# These rows sit outside the contract's jurisdiction and are owned by other
# checks; each stays visible so no registry row silently vanishes.

note 12 "AGENTS.md / CLAUDE.md are outside this contract — audited by Tools/check-agent-surfaces.sh"
note 13 "README.md files and the docs/README.md index are curation with an accuracy-only obligation — audit-and-fix's readme-quality lens plus Tools/check-markdown-links.sh own them"
note 14 "docs/style-guides/ and procedures are repo-local taste — owned by the style guide and instruction-file discovery"
note 15 "scripts/repair_doc_links.py is opt-in and owned by the repo that keeps it — not a shared-conformance concern"

# --- 16: the audit-state directory (opt-in via the declaring config) ----------
# docs/work/audits/ holds the shared audit tracker's per-consumer state. The
# config file IS the opt-in ("declared, not assumed"): a directory without it
# is a half-adopted tree the tracker refuses to serve rather than silently
# treat as empty, and records/ is where its text-mergeable records land.
# Record files must stay parseable JSON — the tracker re-reads them on every
# invocation.
if [ ! -d docs/work/audits ]; then
    absent 16 "docs/work/audits/ not opted in — no tracked-audit state"
elif [ ! -s docs/work/audits/config.toml ]; then
    fail 16 "docs/work/audits/config.toml is missing or empty — the declaring config is the opt-in"
elif [ ! -d docs/work/audits/records ]; then
    fail 16 "docs/work/audits/records/ does not exist — the tracker writes records there"
else
    bad_json=""
    for f in docs/work/audits/records/*.json; do
        [ -e "$f" ] || continue
        if ! python3 -m json.tool "$f" >/dev/null 2>&1; then
            bad_json="$bad_json $f"
        fi
    done
    if [ -n "$bad_json" ]; then
        fail 16 "audit record file(s) not valid JSON:$bad_json"
    else
        pass 16 "docs/work/audits/ with its declaring config and parseable records"
    fi
fi

# --- verdict ------------------------------------------------------------------
echo
if [ "$failures" -ne 0 ]; then
    echo "docs/work conformance: $failures clause(s) failed — see the FAIL lines above; each names the clause, the offending artifact, and the expected correction." >&2
    exit 1
fi
if [ "$notes" -gt 0 ]; then
    echo "$notes clause(s) reported as notes — a note is neither a pass nor a failure."
fi
echo "docs/work conformance: all evaluated clauses conform."
