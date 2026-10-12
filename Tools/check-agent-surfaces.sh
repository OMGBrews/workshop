#!/usr/bin/env bash
# check-agent-surfaces.sh — does this repo still satisfy the harness-agnostic
# conformance checklist?
#
# Mechanizes checks 1-9 and 13 of workshop/docs/harness-agnostic-repos.md
# ("Conformance checklist"). Checks 10 (bootstrap reachable as a plain command)
# and 11 (root sentinels probe AGENTS.md) are deliberately absent: both are
# judgments about whether a script's *body* does the right thing, and the
# mechanical forms of them ("a file named session-start.sh exists", "the string
# AGENTS.md appears in a script") pass on a stub. Check 12 is mechanizable but
# repo-local — the translation seam's path is per-repo knowledge — so it lives
# in each consumer's own verification suite, not here; the standard's Status block says why.
#
# Usage: bash Tools/check-agent-surfaces.sh <repo-root>
# The repo-root argument is REQUIRED: from this location a default would resolve
# to the devtools tree itself, silently auditing the wrong repo. A check that can
# audit the wrong tree is a signal-hygiene violation — every caller passes its
# own root explicitly (this repo: `bash devtools/Tools/check-agent-surfaces.sh .`).
# Exit 0 -> every evaluated assertion holds.  Exit 1 -> at least one failed, and
# every failure is named on stdout with the check number that owns it.  Exit 2 ->
# usage error (repo-root omitted).
#
# Every assertion states a POSITIVE property of an artifact, per
# devtools/docs/signal-hygiene.md: run it against a repo where none of this work
# was done and it goes red, not green. devtools/tests/test-check-agent-surfaces.sh
# pins that by building exactly such a repo and asserting the red.
#
# On the skipped band: the skill checks (8, 9 and 13) that must READ a SKILL.md
# inside an uninitialized submodule cannot be evaluated, and this reports them as
# SKIP rather than folding them into the pass. The structural half still runs
# there, because it reads symlink targets rather than following them. The
# instruction checks (1, 2, 3 and 5) have no skip band: a standing-rule link that
# dangles because its mount is empty is a session running without its rules,
# and every CI that runs this check initializes the mount.

set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "usage: bash Tools/check-agent-surfaces.sh <repo-root>" >&2
    echo "  the repo-root argument is required — a default would silently audit the wrong tree" >&2
    exit 2
fi
root="$1"
cd "$root" || { echo "cannot enter '$root'" >&2; exit 1; }

# Check 5's two ceilings. The pile one is not ours: Codex truncates the merged
# AGENTS.md chain at project_doc_max_bytes, 32 KiB by default, and does it
# silently. The root one is the fleet standard's target, read literally as
# 20,000 bytes (the stricter of the two readings of "20 KB").
PILE_MAX=32768
ROOT_MAX=20000

# The spec's frontmatter field set (agentskills.io/specification). Anything else
# is either a vendor extension a stricter harness may reject, or a typo.
SPEC_FIELDS="name description license compatibility metadata allowed-tools"

# The per-tool instruction files the standard exists to replace.
PER_TOOL_FILES=".cursorrules GEMINI.md .github/copilot-instructions.md .windsurfrules .clinerules .aider.conf.yml .gemini/settings.json"

failures=0
skips=0

pass() { printf 'ok   %-2s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %-2s %s\n' "$1" "$2"; failures=$((failures + 1)); }
skip() { printf 'SKIP %-2s %s\n' "$1" "$2"; skips=$((skips + 1)); }
# A note is neither a pass nor a failure: it keeps a declared escape hatch
# visible without letting it count for or against conformance.
note() { printf 'note %-2s %s\n' "$1" "$2"; }

bytes() { wc -c < "$1" | tr -d ' '; }

# Collapse '.' and '..' textually, without touching the filesystem. Pure shell
# because `realpath --relative-to` is GNU-only and this check has to give the same
# answer on a maintainer's macOS checkout as it does in the Linux devcontainer.
norm_path() {
    local out="" seg
    local IFS=/
    for seg in $1; do
        case "$seg" in
            '' | .) ;;
            ..) out="${out%/*}" ;;
            *) out="$out/$seg" ;;
        esac
    done
    printf '%s' "${out#/}"
}

# Where does .agents/skills/<name> actually live, as a repo-relative path? For a
# shared skill that is a symlink into the devtools submodule; for a project-local
# one it is the directory itself.
canonical_skill_path() {
    local name=$1 target
    if [ -L ".agents/skills/$name" ]; then
        target=$(readlink ".agents/skills/$name")
        case "$target" in
            /*) printf '%s' "$target" ;;
            *) norm_path ".agents/skills/$target" ;;
        esac
    else
        printf '.agents/skills/%s' "$name"
    fi
}

# --- @-import extraction -----------------------------------------------------
#
# Claude Code treats `@path` as an import anywhere in the prose, and skips ones
# inside code spans and fenced blocks. Both exclusions are load-bearing here:
# AGENTS.md legitimately contains `fiw:fiwpass@localhost:25432` inside a fence
# and `@aws-amplify/auth` inside a code span, and a naive grep for '@' calls
# those imports and fails check 4 on a conformant repo.
extract_imports() {
    [ -r "$1" ] || return 0
    awk '
      /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
      fence { next }
      {
        line = $0
        gsub(/`[^`]*`/, "", line)          # drop code spans
        n = split(line, tok, /[[:space:]]+/)
        for (i = 1; i <= n; i++)
          if (tok[i] ~ /^@[^[:space:]]+$/) {
            p = substr(tok[i], 2)
            sub(/[.,;:)"]+$/, "", p)        # trailing sentence punctuation
            if (p != "") print p
          }
      }
    ' "$1"
}

# Is this path inside a submodule that was never initialized? Such a path is
# absent for a reason that is not "somebody deleted the file", and the two must
# not be reported alike: one is a skip, the other is a failure.
in_uninitialized_submodule() {
    local target=$1 sm
    [ -f .gitmodules ] || return 1
    while IFS= read -r sm; do
        [ -n "$sm" ] || continue
        case "$target" in
            "$sm"/*)
                # Initialized submodules have content; an unpopulated one is an
                # empty directory (or absent entirely).
                [ -d "$sm" ] && [ -n "$(ls -A "$sm" 2>/dev/null)" ] && return 1
                return 0
                ;;
        esac
    done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}')
    return 1
}

echo "== agent surfaces: $root"

# --- 1: AGENTS.md exists, and nothing switches it off --------------------------
# Claude Code reads AGENTS.md natively only while no CLAUDE.md, .claude/CLAUDE.md,
# or CLAUDE.local.md exists in the working directory or any directory above it.
# One such file anywhere up the path switches AGENTS.md off with no message, even
# under --debug, while the .claude/rules/ links keep loading — so the session
# looks configured and is missing its instructions. No hook can observe that, so
# the guard is this walk. The per-user memory file ~/.claude/CLAUDE.md is the one
# exemption: it was verified not to suppress AGENTS.md, and failing on it would
# fail every host whose user keeps memory there. A plain ~/CLAUDE.md is not
# exempt; it suppresses like any other ancestor.
if [ ! -f AGENTS.md ]; then
    fail 1 "AGENTS.md is missing — the canonical instruction file does not exist"
fi
user_memory=""
if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
    user_memory="$(cd "$HOME" && pwd -P)/.claude/CLAUDE.md"
fi
suppressors=0; probed=0
dir=$(pwd -P)
while :; do
    probed=$((probed + 1))
    for f in CLAUDE.md CLAUDE.local.md .claude/CLAUDE.md; do
        p="${dir%/}/$f"
        [ "$p" = "$user_memory" ] && continue
        if [ -e "$p" ] || [ -L "$p" ]; then
            fail 1 "$p exists — Claude Code stops reading AGENTS.md for everything beneath it, silently"
            suppressors=$((suppressors + 1))
        fi
    done
    [ "$dir" = / ] && break
    dir=$(dirname "$dir")
done
if [ -f AGENTS.md ] && [ "$suppressors" -eq 0 ]; then
    pass 1 "AGENTS.md exists; no CLAUDE.md, .claude/CLAUDE.md, or CLAUDE.local.md in $probed directories up to /"
fi

# --- 2: every standing rule reaches Claude Code through a rules link -----------
# Each of the three Workshop standing rules is a symlink in .claude/rules/, which
# Claude Code loads eagerly at launch, aimed at the mounted copy:
# ../../<mount>/docs/<rule>.md in a consumer, ../../docs/<rule>.md in Workshop
# itself. All three share one route. The link must resolve and land on the right
# document, so its first line is asserted to be the rule's heading.
#
# There is no skip band here. Every CI that runs this check initializes the
# mount, and a link that dangles because the mount is empty is exactly the
# session that runs without its rules — the failure, not an excuse for it.
STANDING_RULES="signal-hygiene definition-of-done verification-terminology"
rule_heading() {
    case "$1" in
        signal-hygiene) printf '# Signal hygiene' ;;
        definition-of-done) printf '# Definition of done' ;;
        verification-terminology) printf '# Verification terminology' ;;
    esac
}
failures_before_2=$failures
routes=""
for rule in $STANDING_RULES; do
    link=".claude/rules/$rule.md"
    if [ ! -L "$link" ]; then
        if [ -e "$link" ]; then
            fail 2 "$link is a real file, not a link to the mounted rule — a copy drifts from its source"
        else
            fail 2 "$link is missing — Claude Code never loads the $rule rule (bash <mount>/Tools/sync-rules-symlinks.sh . writes it)"
        fi
        continue
    fi
    target=$(readlink "$link")
    route=""
    case "$target" in
        "../../docs/$rule.md")
            route="../../docs" ;;
        ../../*/docs/"$rule.md")
            mount=${target#../../}
            mount=${mount%/docs/"$rule".md}
            case "$mount" in
                '' | . | .. | */*) ;;
                *) route="../../$mount/docs" ;;
            esac
            ;;
    esac
    if [ -z "$route" ]; then
        fail 2 "$link -> $target is not ../../<mount>/docs/$rule.md (one mount component) or ../../docs/$rule.md"
        continue
    fi
    case " $routes " in *" $route "*) ;; *) routes="${routes:+$routes }$route" ;; esac
    if [ ! -r "$link" ]; then
        fail 2 "$link -> $target does not resolve — the $rule rule never loads (is the mount populated?)"
        continue
    fi
    first=$(head -n 1 "$link" | tr -d '\r')
    want=$(rule_heading "$rule")
    if [ "$first" != "$want" ]; then
        fail 2 "$link -> $target opens with '$first', not '$want' — the link lands on the wrong document"
    fi
done
if [ "$(printf '%s' "$routes" | wc -w | tr -d ' ')" -gt 1 ]; then
    fail 2 "standing-rule links use different routes ($routes) — all three come from one mount"
fi
if [ "$failures" -eq "$failures_before_2" ]; then
    pass 2 "3 standing-rule links resolve through $routes/ and open with their headings"
fi

# --- 3: every rules link is also plainly linked from AGENTS.md -----------------
# The failure this catches is silent by construction: the rule stays in context
# for every Claude session through the link, so nobody notices that a Codex
# session never learned it. Every top-level symlink counts — the three standing
# rules and any repo-local one made by hand — and a real topic file does not,
# because Claude-only content is exactly what belongs there and nowhere else.
rule_links=0; missing=""
if [ -d .claude/rules ]; then
    while IFS= read -r link; do
        [ -n "$link" ] || continue
        rule_links=$((rule_links + 1))
        target=$(readlink "$link")
        case "$target" in
            /*) missing="${missing}${link}(absolute target ${target}) "; continue ;;
        esac
        # A Markdown link with that exact repo-relative target, not a bare
        # mention: the point is that a harness with no rules folder can FOLLOW it.
        want=$(norm_path ".claude/rules/$target")
        grep -qF "]($want)" AGENTS.md 2>/dev/null || missing="${missing}${want} "
    done < <(find .claude/rules -mindepth 1 -maxdepth 1 -type l | sort)
fi
if [ "$rule_links" -eq 0 ]; then
    fail 3 "no symlinks under .claude/rules/ — no rules link for AGENTS.md to mirror (check 2 names the missing ones)"
elif [ -z "$missing" ]; then
    pass 3 "all $rule_links rules link(s) are linked from AGENTS.md"
else
    fail 3 "linked into .claude/rules/ but not linked from AGENTS.md: $missing"
fi

# --- 4: no imports in AGENTS.md -----------------------------------------------
if [ -f AGENTS.md ]; then
    stray=$(extract_imports AGENTS.md || true)
    if [ -z "$stray" ]; then
        pass 4 "AGENTS.md contains no @-import lines"
    else
        fail 4 "AGENTS.md contains @-import(s), which render as junk text elsewhere: $(printf '%s' "$stray" | tr '\n' ' ')"
    fi
fi

# --- 5: the always-loaded pile fits, and the root file fits ------------------
# The pile is what every Claude session carries from turn one: AGENTS.md plus
# every rule file under .claude/rules/, measured through the links. A rule with
# `paths:` frontmatter loads only when a matching file is touched, so it is not
# part of the pile. The check runs whenever AGENTS.md exists and never skips: the
# check it replaced was gated on a CLAUDE.md and vanished without a line once
# that file was gone.
has_paths_frontmatter() {
    awk '
      NR == 1 { if ($0 != "---") exit 1; infm = 1; next }
      infm && /^---[[:space:]]*$/ { exit 1 }
      infm && /^paths:/ { found = 1; exit 0 }
      END { if (!found) exit 1 }
    ' "$1"
}
if [ -f AGENTS.md ]; then
    pile=$(bytes AGENTS.md)
    counted=0; scoped=0
    if [ -d .claude/rules ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if has_paths_frontmatter "$f"; then
                scoped=$((scoped + 1))
                continue
            fi
            pile=$((pile + $(bytes "$f")))
            counted=$((counted + 1))
        done < <(find -L .claude/rules -type f -name '*.md' | sort)
    fi
    detail="AGENTS.md + $counted rule file(s)"
    [ "$scoped" -gt 0 ] && detail="$detail; $scoped path-scoped rule(s) not counted"
    if [ "$pile" -lt "$PILE_MAX" ]; then
        pass 5 "always-loaded pile $pile B ($detail), ${PILE_MAX} B cap, $((PILE_MAX - pile)) B headroom"
    else
        fail 5 "always-loaded pile $pile B ($detail) exceeds the ${PILE_MAX} B cap — Codex truncates it silently"
    fi

    a=$(bytes AGENTS.md)
    if [ "$a" -le "$ROOT_MAX" ]; then
        pass 5 "AGENTS.md $a B, ${ROOT_MAX} B target, $((ROOT_MAX - a)) B headroom"
    else
        fail 5 "AGENTS.md $a B exceeds the ${ROOT_MAX} B root target by $((a - ROOT_MAX)) B — trim it or push detail into docs/"
    fi
fi

# --- 6: no per-tool instruction files ----------------------------------------
found=""
for f in $PER_TOOL_FILES; do
    [ -e "$f" ] && found="${found}${f} "
done
if [ -z "$found" ]; then
    pass 6 "no per-tool instruction files ($(printf '%s' "$PER_TOOL_FILES" | wc -w | tr -d ' ') probed)"
else
    fail 6 "per-tool instruction file(s) present — a second source of truth: $found"
fi

# --- 7: the canonical skills surface is not smaller than the bridged one ------
# A count comparison, not "the directory exists": an empty .agents/skills/ and a
# fully populated one both exist.
# A skills surface may carry plain files beside the skills — the generated
# .claude/skills/README.md, signposting that the folder is a bridge and that
# skills are authored in .agents/skills/, is the one this fleet writes. A skill
# is a DIRECTORY, so a regular file is not one: it is neither counted here nor
# link-checked below, where it would otherwise be reported as a skill only one
# harness can run.
#
# Symlinks stay in scope whether or not they resolve. Filtering on -d instead
# would drop every skill whose target is an uninitialized submodule, turning
# the exact breakage check 8 exists to catch into a green "no skills".
is_skill_entry() {
    [ -L "$1" ] || [ -d "$1" ]
}
count_entries() {
    [ -d "$1" ] || { echo 0; return; }
    local n=0 entry
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if is_skill_entry "$entry"; then n=$((n + 1)); fi
    done < <(find "$1" -mindepth 1 -maxdepth 1 ! -name '.*')
    echo "$n"
}
canon=$(count_entries .agents/skills)
bridge=$(count_entries .claude/skills)
if [ "$bridge" -eq 0 ] && [ "$canon" -eq 0 ]; then
    pass 7 "no skills on either surface"
elif [ "$canon" -ge "$bridge" ] && [ "$canon" -gt 0 ]; then
    pass 7 ".agents/skills/ holds $canon skill(s), .claude/skills/ bridges $bridge"
else
    fail 7 ".agents/skills/ holds $canon skill(s) but .claude/skills/ holds $bridge — skills exist that only one harness can run"
fi

# --- 8: every bridged skill resolves to a readable SKILL.md ------------------
# Two halves. The structural half reads symlink TARGETS, so it runs even when
# the shared skills live in an unpopulated submodule; the content half follows
# them, and skips when it cannot. A dangling symlink is created without error
# and looks fine under ls — it fails at invocation time as "Unknown skill".
if [ ! -d .claude/skills ]; then
    if [ "$canon" -gt 0 ]; then
        fail 8 ".agents/skills/ holds $canon skill(s) but there is no .claude/skills/ bridge — Claude Code sees no skills"
    else
        pass 8 "no skills to bridge"
    fi
else
    bad_link=""; bad_body=""; unreadable=""; ok_bodies=0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        is_skill_entry "$entry" || continue
        name=$(basename "$entry")
        if [ -L "$entry" ]; then
            want="../../.agents/skills/$name"
            got=$(readlink "$entry")
            [ "$got" = "$want" ] || bad_link="${bad_link}${name}(-> ${got}) "
        else
            # A real directory here is the expensive mistake: a skill only one
            # harness can run.
            bad_link="${bad_link}${name}(real directory, not a link into .agents/skills/) "
        fi
        if [ -r "$entry/SKILL.md" ]; then
            ok_bodies=$((ok_bodies + 1))
        elif in_uninitialized_submodule "$(canonical_skill_path "$name")"; then
            unreadable="${unreadable}${name} "
        else
            bad_body="${bad_body}${name} "
        fi
    done < <(find .claude/skills -mindepth 1 -maxdepth 1 ! -name '.*')

    if [ -n "$bad_link" ]; then
        fail 8 "bridge link(s) not pointing at ../../.agents/skills/<name>: $bad_link"
    elif [ -n "$bad_body" ]; then
        fail 8 "skill(s) with no readable SKILL.md — 'Unknown skill' mid-task: $bad_body"
    else
        pass 8 "$bridge bridge link(s) well-formed; $ok_bodies SKILL.md readable"
    fi
    [ -n "$unreadable" ] && skip 8 "SKILL.md unreadable (uninitialized submodule): $unreadable"
fi

# --- 9: every SKILL.md validates against the spec ----------------------------
# No published agentskills validator CLI exists to shell out to (checked
# 2026-08-10: `agentskills` is not on PATH and not resolvable from npm), so the
# spec's frontmatter rules are asserted directly: delimited frontmatter, a name
# matching the directory, a non-empty description within the length cap, and no
# field outside the spec's set.
if [ "$canon" -eq 0 ]; then
    pass 9 "no skills to validate"
else
    bad9=""; checked9=0; skipped9=0
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        is_skill_entry "$d" || continue
        name=$(basename "$d")
        skill="$d/SKILL.md"
        if [ ! -r "$skill" ]; then
            if in_uninitialized_submodule "$(canonical_skill_path "$name")"; then
                skipped9=$((skipped9 + 1)); continue
            fi
            bad9="${bad9}${name}: no readable SKILL.md; "
            continue
        fi
        checked9=$((checked9 + 1))
        problems=$(awk -v want="$name" -v allowed=" $SPEC_FIELDS " '
          NR == 1 { if ($0 != "---") { print "no YAML frontmatter (line 1 is not ---)"; exit } ; infm = 1; next }
          infm && /^---[[:space:]]*$/ { infm = 0; nextfile }
          infm && /^[A-Za-z][A-Za-z0-9_-]*:/ {
            key = $0; sub(/:.*/, "", key)
            if (index(allowed, " " key " ") == 0) print "frontmatter field outside the spec set: " key
            val = $0; sub(/^[^:]*:[[:space:]]*/, "", val)
            gsub(/^["'"'"']|["'"'"']$/, "", val)
            if (key == "name") { seen_name = 1; if (val != want) print "name \"" val "\" does not match the directory \"" want "\"" }
            if (key == "description") { seen_desc = 1; if (val == "") print "description is empty"; else if (length(val) > 1024) print "description is " length(val) " chars, over the 1024 cap" }
          }
          END {
            if (infm) print "frontmatter is not closed by a --- line"
            if (!seen_name) print "frontmatter has no name field"
            if (!seen_desc) print "frontmatter has no description field"
          }
        ' "$skill")
        [ -n "$problems" ] && bad9="${bad9}${name}: $(printf '%s' "$problems" | tr '\n' ';' ) "
    done < <(find .agents/skills -mindepth 1 -maxdepth 1 ! -name '.*')

    if [ -z "$bad9" ]; then
        pass 9 "$checked9 SKILL.md validated against the spec frontmatter rules"
    else
        fail 9 "SKILL.md spec violations — $bad9"
    fi
    [ "$skipped9" -gt 0 ] && skip 9 "$skipped9 SKILL.md not validated (uninitialized submodule)"
fi

# --- 13: SKILL.md bodies carry no harness-only mechanics ---------------------
# The standard forbids harness-only mechanics in SKILL.md bodies — `$ARGUMENTS`,
# slash-invocation syntax (`/name`), and the Claude-only frontmatter keys
# `disable-model-invocation` and `context` — unless the skill's frontmatter
# declares `compatibility`, the documented escape hatch. A flag suppressed by
# that declaration is printed as a NOTE, not a pass and not a failure, so the
# escape hatch stays visible; notes never move the exit code.
#
# False-positive tuning, deliberately chosen: fenced code blocks and inline
# backtick spans are stripped before matching `$ARGUMENTS` and slash tokens,
# because a skill QUOTING a mechanism is documentation, not use of it. That
# strip is what makes the house form conformant — mentioning `$ARGUMENTS` in
# backticks with a plain-prose gloss is the correct way to talk about the
# mechanism; writing it bare in prose is what this check flags. The slash pattern additionally requires
# start-of-line or whitespace before the slash and a lowercase skill-name
# shape after it, so URL and path fragments (owner/repo, ../x, docs/standing.md)
# never match. A bare absolute path in prose ("stored in /tmp") is the one
# remaining false-positive shape, and the remedy is the same convention:
# backticks for documentation, `compatibility` for genuine dependence.
if [ "$canon" -eq 0 ]; then
    pass 13 "no skills to check"
else
    bad13=""; checked13=0; skipped13=0; noted13=0
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        is_skill_entry "$d" || continue
        name=$(basename "$d")
        skill="$d/SKILL.md"
        if [ ! -r "$skill" ]; then
            # Check 9 owns the unreadable-SKILL.md failure; 13 stays silent on
            # it rather than double-reporting one root cause, and speaks only
            # for the band 9 cannot evaluate either.
            if in_uninitialized_submodule "$(canonical_skill_path "$name")"; then
                skipped13=$((skipped13 + 1))
            fi
            continue
        fi
        checked13=$((checked13 + 1))

        # Frontmatter, walked the way check 9 walks it: the lines between the
        # opening --- and its closing ---, nothing else.
        fm=$(awk '
          NR == 1 { if ($0 != "---") exit; infm = 1; next }
          infm && /^---[[:space:]]*$/ { exit }
          infm { print }
        ' "$skill")
        declares_compat=0
        grep -q '^compatibility:' <<<"$fm" && declares_compat=1
        claude_keys=$(grep -oE '^(disable-model-invocation|context):' <<<"$fm" | sed 's/:$//' | sort -u | paste -sd' ' - || true)

        # Body mechanics, matched with fenced blocks and inline code spans
        # stripped — the tuning note above is the contract for this.
        stripped=$(awk '
          /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
          fence { next }
          { line = $0; gsub(/`[^`]*`/, "", line); print line }
        ' "$skill")
        flags=""
        # shellcheck disable=SC2016  # the single-quoted $ARGUMENTS is the literal
        #                            # token being searched for — expansion is
        #                            # exactly what must not happen to it.
        grep -qF '$ARGUMENTS' <<<"$stripped" && flags='$ARGUMENTS'
        slashes=$(grep -oE '(^|[[:space:]])/[a-z][a-z0-9-]+' <<<"$stripped" | sed 's/^[[:space:]]*//' | sort -u | paste -sd' ' - || true)
        [ -n "$slashes" ] && flags="${flags}${flags:+; }slash-invocation(s): $slashes"
        [ -n "$claude_keys" ] && flags="${flags}${flags:+; }Claude-only frontmatter: $claude_keys"

        if [ -n "$flags" ]; then
            if [ "$declares_compat" -eq 1 ]; then
                note 13 "$name: $flags — declared compatibility"
                noted13=$((noted13 + 1))
            else
                bad13="${bad13}${name}: $flags; "
            fi
        fi
    done < <(find .agents/skills -mindepth 1 -maxdepth 1 ! -name '.*')

    if [ -z "$bad13" ]; then
        if [ "$noted13" -gt 0 ]; then
            pass 13 "$checked13 SKILL.md bodies clean; $noted13 declared-compatibility note(s) above"
        else
            pass 13 "$checked13 SKILL.md bodies free of harness-only mechanics"
        fi
    else
        fail 13 "harness-only mechanics with no compatibility declaration — $bad13"
    fi
    [ "$skipped13" -gt 0 ] && skip 13 "$skipped13 SKILL.md not checked (uninitialized submodule)"
fi

# --- verdict ------------------------------------------------------------------
echo
if [ "$skips" -gt 0 ]; then
    echo "$skips assertion group(s) SKIPPED — see the SKIP lines above. A skip is not a pass."
fi
if [ "$failures" -ne 0 ]; then
    echo "agent surfaces: $failures check(s) failed — see the FAIL lines above." >&2
    echo "The checklist and the rationale for each check: workshop/docs/harness-agnostic-repos.md" >&2
    exit 1
fi
echo "agent surfaces: all evaluated checks passed."
