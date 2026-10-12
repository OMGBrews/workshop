#!/usr/bin/env bash
# check-definition-of-done.sh — does this repository's
# docs/work/definition-of-done.md conform to docs/definition-of-done-schema.md?
#
# A page carrying `## Repository profile` is in the schema's shape and is held
# to every clause below (so is one that lost only that heading; see the shape
# test). A page without it is in the older single-table shape:
# the schema's Migration section makes that transitional, so the page is held
# only to the old bar (a level-one heading and at least two lines of content)
# and reported as transitional, never as conformant.
#
# One line per clause, with the verdict words of
# Tools/check-docs-work-conformance.sh plus one more:
#   ok          — the clause's assertions all hold
#   FAIL        — an assertion is violated; the line names the section and the
#                 offending value
#   unavailable — a declared artifact sits inside a Git submodule that is not
#                 initialized in this checkout, so it cannot be read here
# then exactly one verdict line, which callers and tests read:
#   definition of done: conformant
#   definition of done: transitional (older shape)
#   definition of done: incomplete — N artifact(s) unavailable
#   definition of done: N clause(s) failed
#
# Usage: bash Tools/check-definition-of-done.sh <repo-root> [--conformant]
# Exit 0 -> conformant, transitional, or incomplete.  Exit 1 -> at least one
# clause failed, or, under --conformant, the page is transitional or
# incomplete.  Exit 2 -> usage error.  The text, not the number, is the
# diagnostic interface.
#
# The check never queries GitHub. A platform-enforced declaration must carry a
# dated observation citation; whether the platform still agrees is a live audit,
# not a document check. Commands are resolved against the artifacts the
# repository tracks (a Makefile target, a tracked path, a workflow step), so a
# page cannot pass by naming a command that does not exist here.
#
# Every assertion states a POSITIVE property of the page or of an artifact it
# names, per docs/signal-hygiene.md; tests/test-check-definition-of-done.sh
# builds a conformant fixture per profile and a failing fixture per rejected
# shape and pins both outcomes.

set -euo pipefail

usage() {
    echo "usage: bash Tools/check-definition-of-done.sh <repo-root> [--conformant]" >&2
    echo "  one repo-root argument is required — a default would silently audit the wrong tree" >&2
    exit 2
}

conformant_only=0
root=""
for arg in "$@"; do
    case "$arg" in
        --conformant) conformant_only=1 ;;
        -*) echo "unknown option: $arg" >&2; usage ;;
        *)
            [ -z "$root" ] || usage
            root="$arg"
            ;;
    esac
done
[ -n "$root" ] || usage
cd "$root" || { echo "cannot enter '$root'" >&2; exit 2; }
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "not a Git worktree: '$root' — declared commands are resolved against tracked files" >&2
    exit 2
fi
if [ "$(git rev-parse --show-toplevel)" != "$(pwd -P)" ]; then
    echo "not the Git worktree root: '$root' — pass the repo root, not a subdirectory" >&2
    exit 2
fi
repo="$(pwd -P)"
page=docs/work/definition-of-done.md

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
unavailable=0

pass() { printf 'ok   %-2s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %-2s %s\n' "$1" "$2"; failures=$((failures + 1)); }

verdict() {
    echo
    if [ "$failures" -ne 0 ]; then
        echo "definition of done: $failures clause(s) failed"
        exit 1
    fi
    if [ "$unavailable" -ne 0 ]; then
        echo "$unavailable artifact(s) unavailable — see the unavailable lines above. An unavailable is not a pass."
        echo "definition of done: incomplete — $unavailable artifact(s) unavailable"
        [ "$conformant_only" -eq 1 ] && exit 1
        exit 0
    fi
    echo "definition of done: $1"
    if [ "$1" != conformant ] && [ "$conformant_only" -eq 1 ]; then
        exit 1
    fi
    exit 0
}

echo "== definition of done: $root"

if [ ! -f "$page" ]; then
    fail 0 "docs/work/definition-of-done.md is missing — every repo states its required evidence here, and a repo with no automated checks owes the one line that says so"
    verdict failed
fi

# Strip every HTML comment except the two DOCS-ONLY sentinel lines: a guidance
# comment left in place must not count as content, and the sentinels are what
# clause 7 reads. A line that was only a comment becomes blank.
LC_ALL=C awk '
    { sub(/\r$/, "") }
    !inc && /^<!-- DOCS-ONLY:(BEGIN|END)/ { print; next }
    {
        out = ""; s = $0
        while (1) {
            if (inc) {
                p = index(s, "-->")
                if (p == 0) { s = ""; break }
                s = substr(s, p + 3); inc = 0
            }
            p = index(s, "<!--")
            if (p == 0) { out = out s; break }
            out = out substr(s, 1, p - 1); s = substr(s, p + 4); inc = 1
        }
        print out
    }
' "$page" >"$work/page.md"

# --- the older single-table shape: transitional ------------------------------
# The schema distinguishes the shapes by `## Repository profile`. A page that
# lost that one heading but carries the schema's docs-only heading or two of
# its other sections is a damaged schema page, not an older one, and is held to
# the schema clauses so the loss fails instead of reading as transitional. No
# older-shape page in the fleet carries more than one of those headings.
schema_sections=$(grep -cE '^## (Pre-commit feedback|Landing requirements|Release requirements|Deployment requirements|Known gaps)[[:space:]]*$' "$work/page.md" || true)
if ! grep -q '^## Repository profile[[:space:]]*$' "$work/page.md" \
   && ! grep -q '^### Docs-only surface[[:space:]]*$' "$work/page.md" \
   && [ "$schema_sections" -lt 2 ]; then
    # The old clause-6 bar, kept verbatim, because consumers and
    # tests/test-check-docs-work-conformance.sh read these strings.
    heading=$(grep -c '^# ' "$page" || true)
    body=$(grep -cv '^[[:space:]]*$\|^#' "$page" || true)
    if [ "$heading" -lt 1 ]; then
        fail t "docs/work/definition-of-done.md has no level-1 heading — this is not a written document"
    elif [ "$body" -lt 2 ]; then
        fail t "docs/work/definition-of-done.md is a heading and $body line(s) of content — it names no required evidence and does not say there is none"
    else
        pass t "docs/work/definition-of-done.md ($heading heading, $body content line(s)) has no '## Repository profile' — read as the older single-table shape, which docs/definition-of-done-schema.md treats as transitional; the schema clauses do not apply until it migrates"
    fi
    verdict "transitional (older shape)"
fi

# --- the schema shape: clauses 1-7 and 9 from the page itself -----------------
# The parser emits one record per finding:
#   F <tab> clause <tab> problem      a failure
#   O <tab> clause <tab> summary      the clause held
#   C <tab> section <tab> requirement <tab> command   a Command: value to resolve
LC_ALL=C awk '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
# A one-word value: trimmed, backticks and one trailing period removed, lowercased.
function token(s) {
    s = trim(s); gsub(/`/, "", s); sub(/\.$/, "", s); return tolower(trim(s))
}
function f(c, msg) { print "F\t" c "\t" msg; bad[c] = 1 }
function o(c, msg) { if (!(c in summary)) summary[c] = msg }
function in_list(v, list,   n, i, a) {
    n = split(list, a, "|")
    for (i = 1; i <= n; i++) if (v == a[i]) return 1
    return 0
}
# "" when s opens with `None —` or `Not applicable —` and a reason; else why not.
function none_form(s,   l) {
    l = tolower(s)
    if (l ~ /^(none|not applicable) —[ ]+[^ ]/) return ""
    if (l ~ /^(none|not applicable) —[ ]*$/) return "`" s "` gives no reason after the dash"
    if (l ~ /^(none|not applicable)[ ]*(-|–|:)/) return "`" s "` must use an em dash (`—`) after `None` or `Not applicable`"
    return "no"
}
function is_stage(s) {
    return s == "Pre-commit feedback" || s == "Landing requirements" ||
           s == "Release requirements" || s == "Deployment requirements"
}
function close_sub() {
    if (nsub > 0) subval[nsub] = trim(subval[nsub])
}
function close_req(   want, n, i, k, lab, val, tok, labels, nl, fixed, ci_ok) {
    if (!inreq) return
    close_sub()
    inreq = 0
    ci_ok = (reqsect == "Landing requirements")
    fixed = "Command|Pass condition|Applies to|Evidence type|Enforcement|Evidence state"
    if (ci_ok) fixed = fixed "|CI status"
    nl = split(fixed, labels, "|")
    # CI status outside landing is named on its own, then left out of the
    # positional comparison so it reads as one problem, not two.
    n = 0
    for (i = 1; i <= nsub; i++) {
        if (!ci_ok && tolower(sublab[i]) == "ci status") {
            f(4, "`## " reqsect "` requirement **" reqname "**: `CI status` belongs only under `## Landing requirements`")
            continue
        }
        n++; plab[n] = sublab[i]; pval[n] = subval[i]
    }
    for (i = 1; i <= nl; i++) {
        want = labels[i]
        if (i > n) {
            f(4, "`## " reqsect "` requirement **" reqname "**: missing `" want ":` (sub-lines run " fixed_text(labels, nl) ")")
            continue
        }
        lab = plab[i]; val = pval[i]
        if (tolower(lab) != tolower(want)) {
            if (lab == "") {
                f(4, "`## " reqsect "` requirement **" reqname "**: sub-line " i " `" val "` is not `Label: value`; expected `" want ":`")
            } else {
                k = in_list(tolower(lab), tolower(fixed)) ? "out of order" : "an unknown label"
                f(4, "`## " reqsect "` requirement **" reqname "**: sub-line " i " is `" lab ":` (" k "); expected `" want ":`")
            }
            continue
        }
        if (val == "") {
            f(4, "`## " reqsect "` requirement **" reqname "**: `" want ":` is empty")
            continue
        }
        tok = token(val)
        if (want == "Command") {
            print "C\t" reqsect "\t" reqname "\t" val
        } else if (want == "Evidence type" && !in_list(tok, "automated|manual")) {
            f(4, "`## " reqsect "` requirement **" reqname "**: Evidence type `" val "` is not one of automated, manual")
        } else if (want == "Enforcement") {
            if (!in_list(tok, "advisory|procedural|platform-enforced")) {
                f(4, "`## " reqsect "` requirement **" reqname "**: Enforcement `" val "` is not one of advisory, procedural, platform-enforced")
                if (reqsect == "Landing requirements") land_invalid = 1
            } else {
                if (tok == "platform-enforced") platform_declared = platform_declared "requirement **" reqname "** in `## " reqsect "`; "
                if (tok == "platform-enforced" && reqsect == "Pre-commit feedback")
                    f(4, "`## Pre-commit feedback` requirement **" reqname "**: Enforcement `platform-enforced` is an error here — a hook is at most a local commit gate")
                if (reqsect == "Landing requirements" && rank[tok] > land_max) land_max = rank[tok]
            }
        } else if (want == "Evidence state" && !in_list(tok, "available|unavailable|unconfirmed")) {
            f(4, "`## " reqsect "` requirement **" reqname "**: Evidence state `" val "` is not one of available, unavailable, unconfirmed")
        }
    }
    nreq[reqsect]++
    if (reqsect == "Landing requirements") nland++
}
function fixed_text(labels, nl,   i, s) {
    s = labels[1]
    for (i = 2; i <= nl; i++) s = s ", " labels[i]
    return s
}
function close_pkey() {
    if (inpkey) { pval_[npk] = trim(pval_[npk]); inpkey = 0 }
}
BEGIN {
    nexp = split("Repository profile|Pre-commit feedback|Landing requirements|Release requirements|Deployment requirements|Known gaps", exp_, "|")
    rank["advisory"] = 1; rank["procedural"] = 2; rank["platform-enforced"] = 3
    name_of[1] = "advisory"; name_of[2] = "procedural"; name_of[3] = "platform-enforced"
    sect = ""; land_max = 0
}
# Fenced blocks are opaque: never headings, bullets, or sentinels.
/^[ ]*(```|~~~)/ { fence = !fence; if (sect != "") content[sect] = 1; next }
fence { if (sect != "") content[sect] = 1; next }
/^# / {
    h1++
    if (sect != "") f(1, "level-one heading `" $0 "` appears inside `## " sect "`; the page has exactly one, at the top")
    next
}
/^## / {
    close_req(); close_pkey()
    sect = trim(substr($0, 4)); nh2++; h2[nh2] = sect
    indos = 0
    next
}
/^### / {
    close_req(); close_pkey()
    h = trim(substr($0, 5))
    if (sect == "Landing requirements") {
        if (indos) f(7, "`### " h "` follows `### Docs-only surface`; the docs-only surface is the last heading in `## Landing requirements`")
        if (h == "Docs-only surface") { dos++; indos = 1 }
    } else if (h == "Docs-only surface") {
        f(7, "`### Docs-only surface` sits under `## " (sect == "" ? "(no section)" : sect) "`; it belongs at the end of `## Landing requirements`")
    }
    next
}
/^<!-- DOCS-ONLY:BEGIN/ || /^<!-- DOCS-ONLY:END/ {
    which = ($0 ~ /BEGIN/) ? "BEGIN" : "END"
    if (indos) {
        if (which == "BEGIN") { begins++; if (!begin_at) begin_at = NR }
        else { ends++; if (!end_at) end_at = NR }
    } else {
        f(7, "a DOCS-ONLY " which " sentinel sits outside `### Docs-only surface` (in `## " (sect == "" ? "(no section)" : sect) "`)")
    }
    next
}
# Before the first level-two heading: the scope statement.
sect == "" {
    if ($0 !~ /^[ \t]*$/ && h1) scope++
    next
}
sect == "Repository profile" {
    if ($0 ~ /^- /) {
        close_pkey()
        npk++; inpkey = 1
        line = substr($0, 3)
        p = index(line, ":")
        if (p == 0) { pkey[npk] = ""; pval_[npk] = line }
        else { pkey[npk] = trim(substr(line, 1, p - 1)); pval_[npk] = substr(line, p + 1) }
    } else if ($0 ~ /^[ \t]+[^ \t]/ && inpkey) {
        pval_[npk] = pval_[npk] " " trim($0)
    } else if ($0 !~ /^[ \t]*$/) {
        close_pkey()
    }
    next
}
is_stage(sect) {
    if (tolower($0) ~ /strengthened/) strengthened_seen = 1
    if (indos) {
        if ($0 !~ /^[ \t]*$/) dostext = dostext " " tolower($0)
        next
    }
    if ($0 ~ /^[ \t]*$/) next
    content[sect] = 1
    if ($0 ~ /^- \*\*/) {
        close_req()
        inreq = 1; reqsect = sect; nsub = 0
        reqname = substr($0, 5); p = index(reqname, "**")
        if (p > 0) reqname = substr(reqname, 1, p - 1)
        if (!(sect in first)) first[sect] = $0
        next
    }
    if (inreq && $0 ~ /^  - /) {
        close_sub()
        nsub++
        line = substr($0, 5); p = index(line, ":")
        if (p == 0) { sublab[nsub] = ""; subval[nsub] = line }
        else { sublab[nsub] = trim(substr(line, 1, p - 1)); subval[nsub] = substr(line, p + 1) }
        next
    }
    if (inreq && $0 ~ /^[ \t]/) {
        if (nsub > 0) subval[nsub] = subval[nsub] " " trim($0)
        next
    }
    close_req()
    if (!(sect in first)) first[sect] = trim($0)
    next
}
sect == "Known gaps" {
    if ($0 ~ /^[ \t]*$/) next
    if (!gap_kind) {
        if ($0 ~ /^-([ \t]|$)/) gap_kind = "list"
        else {
            gap_kind = "none"
            why = none_form(trim($0))
            if (why == "no") f(9, "`## Known gaps` opens with `" trim($0) "`; write a bullet list or one line beginning `None —`")
            else if (why != "") f(9, "`## Known gaps`: " why)
        }
    }
    if (gap_kind == "list") {
        if ($0 ~ /^-([ \t]|$)/) {
            ngaps++
            if (trim(substr($0, 2)) == "") f(9, "`## Known gaps` holds a bare `-` bullet that names no gap")
        } else if ($0 !~ /^[ \t]/) {
            f(9, "`## Known gaps` is a bullet list, but `" trim($0) "` is neither a bullet nor its indented continuation")
        }
    }
    next
}
END {
    close_req(); close_pkey()

    # --- 1: heading and scope statement
    if (h1 == 0) f(1, "no level-one heading")
    else if (h1 > 1) f(1, h1 " level-one headings; the page has exactly one")
    if (h1 && !scope) f(1, "no scope statement between the level-one heading and `## Repository profile`")
    o(1, "one level-one heading and a scope statement")

    # --- 2: the six sections, spelled exactly, in order
    for (i = 1; i <= nexp; i++) {
        found = 0
        for (j = 1; j <= nh2; j++) if (h2[j] == exp_[i]) found++
        if (!found) f(2, "missing section `## " exp_[i] "`")
        else if (found > 1) f(2, "section `## " exp_[i] "` appears " found " times")
    }
    gaps_at = 0
    for (j = 1; j <= nh2; j++) if (h2[j] == "Known gaps") { gaps_at = j; break }
    k = 0; order = ""
    for (j = 1; j <= nh2 && (gaps_at == 0 || j <= gaps_at); j++) {
        known = 0
        for (i = 1; i <= nexp; i++) if (h2[j] == exp_[i]) known = 1
        if (!known) f(2, "unexpected section `## " h2[j] "` before `## Known gaps`; further sections may only follow it")
        else { k++; seen[k] = h2[j] }
        order = order (order == "" ? "" : ", ") "`## " h2[j] "`"
    }
    misordered = 0
    for (i = 1; i <= k && i <= nexp; i++) if (seen[i] != exp_[i]) misordered = 1
    if (misordered) f(2, "sections out of order: found " order)
    o(2, "the six level-two sections, in order")

    # --- 3: repository profile keys and values
    if (!(nh2 && sect_present("Repository profile"))) {
        f(3, "no `## Repository profile` section")
    } else {
        nkeys = split("Declared unit|Profile|Production evidence|Default landing route|Landing enforcement|Enforcement evidence|Strengthened for", keys, "|")
        for (i = 1; i <= npk; i++) {
            if (pkey[i] == "") { f(3, "`## Repository profile` line `- " pval_[i] "` is not `- Key: value`"); continue }
            known = 0
            for (j = 1; j <= nkeys; j++) if (tolower(pkey[i]) == tolower(keys[j])) { known = 1; kname = keys[j] }
            if (!known) { f(3, "`## Repository profile` has an unknown key `" pkey[i] "`"); continue }
            if (kname in val) { f(3, "`## Repository profile` repeats the key `" kname "`"); continue }
            val[kname] = pval_[i]; kpos[kname] = ++kseq; korder[kseq] = kname
        }
        for (j = 1; j <= nkeys; j++) {
            if (!(keys[j] in val)) f(3, "`## Repository profile` is missing the key `" keys[j] ":`")
            else if (val[keys[j]] == "") f(3, "`## Repository profile` key `" keys[j] ":` is empty")
        }
        inorder = 1; last = 0
        for (j = 1; j <= nkeys; j++) if (keys[j] in val) { if (kpos[keys[j]] < last) inorder = 0; last = kpos[keys[j]] }
        if (!inorder) {
            ko = ""
            for (j = 1; j <= kseq; j++) ko = ko (ko == "" ? "" : ", ") korder[j]
            f(3, "`## Repository profile` keys out of order: found " ko)
        }

        prof = val["Profile"]
        if (prof != "") {
            pt = trim(prof)
            if (pt ~ /^\[[^]]*\]\(/) { pt = substr(pt, 2); pt = substr(pt, 1, index(pt, "]") - 1) }
            gsub(/\*/, "", pt)
            pt = token(pt)
            if (!in_list(pt, "content or scaffold|active local software|shared or released software|production or deployed system"))
                f(3, "`## Repository profile` Profile `" prof "` is not one of the four profiles in docs/verification-profiles.md: content or scaffold, active local software, shared or released software, production or deployed system")
        }
        pe = val["Production evidence"]
        if (pe != "" && pt != "") {
            why = none_form(pe)
            if (pt == "production or deployed system") {
                if (tolower(pe) ~ /^not applicable/) f(3, "`## Repository profile` Production evidence `" pe "` — a production or deployed system names who operates it and the current evidence that it is operated")
            } else if (tolower(pe) !~ /^not applicable/) {
                f(3, "`## Repository profile` Production evidence `" pe "` — for the " pt " profile this is `Not applicable — " pt "`")
            } else if (why != "") {
                f(3, "`## Repository profile` Production evidence: " why)
            }
        }
        rt = val["Default landing route"]
        if (rt != "" && tolower(trim(rt)) !~ /^(pull request|authorized direct push)/)
            f(3, "`## Repository profile` Default landing route `" rt "` is neither `pull request` nor `authorized direct push`")
        le = val["Landing enforcement"]
        let_ = token(le)
        if (le != "" && !in_list(let_, "advisory|procedural|platform-enforced"))
            f(3, "`## Repository profile` Landing enforcement `" le "` is not one of advisory, procedural, platform-enforced")
        if (let_ == "platform-enforced") platform_declared = "the profile Landing enforcement; " platform_declared
        sf = val["Strengthened for"]
        if (sf != "" && token(sf) != "none" && !strengthened_seen)
            f(3, "`## Repository profile` Strengthened for `" sf "` names a risk, but no requirement in sections 2-5 is marked as strengthened")
    }
    o(3, "seven profile keys, in order, with values from the schema vocabulary")

    # --- 4: requirement grammar in the four stage sections
    split("Pre-commit feedback|Landing requirements|Release requirements|Deployment requirements", stages, "|")
    for (i = 1; i <= 4; i++) {
        s = stages[i]
        if (!sect_present(s)) { f(4, "no `## " s "` section to read"); continue }
        if (nreq[s] > 0) continue
        if (!(s in first)) {
            f(4, "`## " s "` is empty; write requirement bullets or one line beginning `None —` or `Not applicable —`")
            continue
        }
        why = none_form(first[s])
        if (why == "no") f(4, "`## " s "` opens with `" first[s] "`, which is neither a `- **Requirement**` bullet nor a line beginning `None —` or `Not applicable —`")
        else if (why != "") f(4, "`## " s "`: " why)
    }
    o(4, "every stage section declares requirements in the schema grammar or one None/Not applicable line")

    # --- 5: profile landing enforcement summarizes landing requirements
    if (let_ == "" || !(let_ in rank)) {
        f(5, "cannot compare: the profile Landing enforcement is missing or invalid (clause 3 names it)")
    } else if (land_invalid) {
        f(5, "cannot compare: a landing requirement carries an invalid Enforcement (clause 4 names it)")
    } else if (nland == 0) {
        if (let_ == "platform-enforced") f(5, "Landing enforcement `platform-enforced` with no landing requirement for a platform to enforce")
        o(5, "Landing enforcement `" let_ "` with no landing requirements")
    } else if (rank[let_] != land_max) {
        f(5, "Landing enforcement `" let_ "` is " (rank[let_] > land_max ? "stronger" : "weaker") " than the strongest landing requirement, `" name_of[land_max] "`")
    }
    o(5, "Landing enforcement `" let_ "` equals the strongest landing requirement")

    # --- 6: a platform-enforced declaration carries a dated observation
    if (platform_declared == "") {
        o(6, "no platform-enforced declaration, so no observation citation is required")
    } else {
        ev = val["Enforcement evidence"]; evl = tolower(trim(ev)); evt = token(ev)
        sub(/; $/, "", platform_declared)
        if (evt == "" || evt == "unconfirmed" || evt == "none") {
            f(6, "platform-enforced is declared (" platform_declared ") but Enforcement evidence is `" ev "` — cite the observation of the rule, or declare the strongest confirmed level and list the rule under known gaps")
        } else {
            if (evl !~ /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)
                f(6, "platform-enforced is declared (" platform_declared ") but Enforcement evidence carries no observation date (YYYY-MM-DD)")
            if (index(evl, "gh api") == 0 && index(evl, "rulesets") == 0 && index(evl, "rules/branches") == 0 &&
                index(evl, "branch protection") == 0 && evl !~ /https?:\/\//)
                f(6, "platform-enforced is declared (" platform_declared ") but Enforcement evidence names no observation method (`gh api`, a rulesets or rules/branches view, branch protection, or a URL)")
        }
        o(6, "platform-enforced is declared and Enforcement evidence cites a dated observation (not re-observed here)")
    }

    # --- 7: the docs-only surface
    if (dos == 0) f(7, "no `### Docs-only surface` heading in `## Landing requirements`")
    else if (dos > 1) f(7, "`### Docs-only surface` appears " dos " times")
    else {
        sentence = index(dostext, "no docs-only surface") > 0
        block = (begins > 0 || ends > 0)
        if (block && (begins != 1 || ends != 1 || end_at < begin_at))
            f(7, "the DOCS-ONLY block needs exactly one BEGIN sentinel followed by one END sentinel")
        if (block && sentence) f(7, "`### Docs-only surface` carries both the DOCS-ONLY block and a no-surface sentence; keep exactly one")
        if (!block && !sentence) f(7, "`### Docs-only surface` carries neither the DOCS-ONLY block nor a sentence stating that no docs-only surface is declared")
        if (block) o(7, "docs-only surface declared by a DOCS-ONLY block (its syntax is owned by Tools/docs-only-diff.sh)")
        else o(7, "no docs-only surface declared")
    }

    # --- 9: known gaps
    if (!sect_present("Known gaps")) f(9, "no `## Known gaps` section")
    else if (!gap_kind) f(9, "`## Known gaps` is empty; write a bullet list or one line beginning `None —`")
    else if (gap_kind == "list") o(9, ngaps " known gap(s) listed")
    else o(9, "no known gaps, with what was checked")

    for (c in summary) print "O\t" c "\t" summary[c]
}
function sect_present(s,   j) {
    for (j = 1; j <= nh2; j++) if (h2[j] == s) return 1
    return 0
}
' "$work/page.md" >"$work/records"

# --- 8: every declared command resolves to a tracked artifact -----------------

# Gitlinks (submodule entries) tracked by the repository at $1.
gitlinks() {
    git -C "$1" -c core.quotepath=off ls-files -s | awk -F'\t' '{ split($1, a, " "); if (a[1] == "160000") print $2 }'
}

# resolve_path <repo-dir> <path> <display-prefix>: prints `tracked`,
# `untracked`, or `unavailable <gitlink>`. `git ls-files --error-unmatch` does
# not look inside a gitlink, so a path under one is resolved inside the
# submodule when it is populated and reported unavailable when it is not.
resolve_path() {
    local dir="$1" path="$2" prefix="$3" g best="" top
    if git -C "$dir" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
        echo tracked
        return
    fi
    while IFS= read -r g; do
        case "$path" in
            "$g"/*) [ "${#g}" -gt "${#best}" ] && best="$g" ;;
        esac
    done < <(gitlinks "$dir")
    if [ -z "$best" ]; then
        echo untracked
        return
    fi
    top=""
    if [ -d "$dir/$best" ]; then
        top="$(git -C "$dir/$best" rev-parse --show-toplevel 2>/dev/null || true)"
    fi
    if [ -n "$top" ] && [ "$top" = "$(cd "$dir/$best" && pwd -P)" ]; then
        resolve_path "$dir/$best" "${path#"$best"/}" "$prefix$best/"
    else
        echo "unavailable $prefix$best"
    fi
}

# Normalize a repository-relative path: drop ./ and empty segments, fold ..,
# strip a trailing slash. Prints nothing when the path leaves the repository.
normalize_path() {
    local IFS=/ part out=()
    # shellcheck disable=SC2206  # word splitting on / is the point
    local parts=($1)
    for part in "${parts[@]}"; do
        case "$part" in
            '' | .) ;;
            ..)
                [ "${#out[@]}" -gt 0 ] || return 0
                unset 'out[${#out[@]}-1]'
                ;;
            *) out+=("$part") ;;
        esac
    done
    printf '%s' "${out[*]}"
}

# Rule targets declared by a Makefile, one per line. A rule line has a colon
# before any equals sign; several targets may share it.
make_targets() {
    awk '
        /^\t/ || /^[ \t]*#/ { next }
        {
            line = $0; c = index(line, ":"); e = index(line, "=")
            if (c == 0 || (e > 0 && e < c) || substr(line, c + 1, 1) == "=") next
            n = split(substr(line, 1, c - 1), t, /[ \t]+/)
            for (i = 1; i <= n; i++) if (t[i] != "") print t[i]
        }
    ' "$1"
}

# Every `run:` value in the tracked workflow files, one command per line.
workflow_runs() {
    local wf
    while IFS= read -r wf; do
        [ -f "$wf" ] || continue
        awk -v q="'" '
            function ind(s) { match(s, /^[ ]*/); return RLENGTH }
            function clean(s) {
                sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
                if (s ~ /^".*"$/ || (substr(s, 1, 1) == q && substr(s, length(s)) == q)) s = substr(s, 2, length(s) - 2)
                return s
            }
            inblock {
                if ($0 ~ /^[ \t]*$/) next
                if (ind($0) > keyind) { print clean($0); next }
                inblock = 0
            }
            /^[ \t]*(- )?run:/ {
                v = $0; sub(/^[ \t]*(- )?run:[ \t]*/, "", v)
                if (v ~ /^[|>]/) {
                    keyind = ind($0); if ($0 ~ /^[ \t]*- /) keyind += 2
                    inblock = 1; next
                }
                print clean(v)
            }
        ' "$wf"
    done < <(git ls-files -- '.github/workflows/*.yml' '.github/workflows/*.yaml')
}

collapse() { printf '%s' "$1" | tr -s ' \t' '  ' | sed 's/^ //; s/ $//'; }

workflow_runs >"$work/runs"

cmd_fail=""       # one problem per resolved value, joined
cmd_ok=""
unavail_lines=()
manual=0

# resolve_command <section> <requirement> <value>
resolve_command() {
    local sect="$1" req="$2" value="$3" cmd norm seg tok i make_dir make_file
    local artifacts=0 problems="" unav=() cwd="" first target res mf p j line
    local -a toks segs targets
    # With backtick spans, the spans are the command and the words around them
    # are prose; without them, the whole value is, less one sentence period.
    if [[ "$value" == *'`'*'`'* ]]; then
        cmd="$(printf '%s\n' "$value" | awk -F'`' '{ for (i = 2; i <= NF; i += 2) if ($i != "") printf "%s%s", (n++ ? " && " : ""), $i }')"
    else
        cmd="$value"
        [[ "$cmd" == *[!\ ]. ]] && cmd="${cmd%.}"
    fi
    norm="$(collapse "$cmd")"
    if [ "$(printf '%s' "$norm" | tr '[:upper:]' '[:lower:]')" = none ]; then
        manual=$((manual + 1))
        return
    fi
    local where="\`## $sect\` requirement **$req**"

    # A workflow step: the command text is the run: value of a tracked step.
    if grep -Fxq -- "$norm" <(while IFS= read -r line; do collapse "$line"; echo; done <"$work/runs"); then
        artifacts=$((artifacts + 1))
    fi

    # Split only to find cd prefixes and tokens; the value is judged as a whole.
    seg="$norm"
    seg="${seg//&&/$'\n'}"
    seg="${seg//||/$'\n'}"
    seg="${seg//;/$'\n'}"
    seg="${seg//|/$'\n'}"
    seg="${seg//, then /$'\n'}"
    segs=()
    while IFS= read -r line; do segs+=("$line"); done <<<"$seg"
    for seg in "${segs[@]}"; do
        read -ra toks <<<"$seg" || true
        [ "${#toks[@]}" -gt 0 ] || continue
        i=0
        while [ "$i" -lt "${#toks[@]}" ] && [[ "${toks[$i]}" == [A-Za-z_]*=* ]]; do i=$((i + 1)); done
        [ "$i" -lt "${#toks[@]}" ] || continue
        first="${toks[$i]}"
        if [ "$first" = cd ]; then
            p="$(normalize_path "$cwd${toks[$((i + 1))]:-}")"
            if [ -z "$p" ]; then
                problems="${problems}\`cd ${toks[$((i + 1))]:-}\` leaves the repository; "
                continue
            fi
            res="$(resolve_path "$repo" "$p" "")"
            case "$res" in
                tracked) cwd="$p/" ;;
                unavailable*) unav+=("$p|${res#unavailable }"); cwd="$p/" ;;
                *) problems="${problems}\`cd $p\` names a directory with no tracked files; " ;;
            esac
            continue
        fi
        if [ "$first" = make ]; then
            make_dir="$cwd"; make_file=""; targets=()
            j=$((i + 1))
            while [ "$j" -lt "${#toks[@]}" ]; do
                tok="${toks[$j]}"
                case "$tok" in
                    -C) j=$((j + 1)); make_dir="$cwd${toks[$j]:-}/" ;;
                    -f) j=$((j + 1)); make_file="${toks[$j]:-}" ;;
                    -*|*=*) ;;
                    *) [[ "$tok" =~ ^[0-9]+$ ]] || targets+=("$tok") ;;
                esac
                j=$((j + 1))
            done
            mf=""
            if [ -n "$make_file" ]; then
                mf="$(normalize_path "$make_dir$make_file")"
            else
                for p in Makefile makefile GNUmakefile; do
                    p="$(normalize_path "$make_dir$p")"
                    if [ "$(resolve_path "$repo" "$p" "")" != untracked ]; then mf="$p"; break; fi
                done
                [ -n "$mf" ] || mf="$(normalize_path "${make_dir}Makefile")"
            fi
            res="$(resolve_path "$repo" "$mf" "")"
            case "$res" in
                tracked)
                    make_targets "$repo/$mf" >"$work/targets"
                    if [ "${#targets[@]}" -eq 0 ]; then
                        if [ -s "$work/targets" ]; then artifacts=$((artifacts + 1)); else problems="${problems}tracked $mf declares no rule; "; fi
                    fi
                    for target in "${targets[@]}"; do
                        if grep -Fxq -- "$target" "$work/targets"; then
                            artifacts=$((artifacts + 1))
                        else
                            problems="${problems}make target \`$target\` is not a rule in tracked $mf; "
                        fi
                    done
                    ;;
                unavailable*) unav+=("$mf|${res#unavailable }") ;;
                *) problems="${problems}\`make\` has no tracked Makefile at ${mf}; " ;;
            esac
            continue
        fi
        # Every path-shaped token must resolve; any one that does is an artifact.
        for tok in "${toks[@]:$i}"; do
            while [[ "$tok" == [\"\'\(]* ]]; do tok="${tok#?}"; done
            while [[ "$tok" == *[\"\'\)] ]]; do tok="${tok%?}"; done
            case "$tok" in
                -* | *=* | *'$'* | *'<'* | *'>'* | *://* | '') continue ;;
            esac
            # A glob with no directory part is a pattern argument, not a path.
            [[ "$tok" == *[*?[]* && "$tok" != */* ]] && continue
            case "$tok" in
                */* | *.sh | *.py | *.pl | *.js | *.csproj | *.yml | *.yaml) ;;
                *) continue ;;
            esac
            if [[ "$tok" == /* || "$tok" == '~'* ]]; then
                problems="${problems}\`$tok\` is outside the repository; "
                continue
            fi
            p="$(normalize_path "$cwd$tok")"
            if [ -z "$p" ]; then
                problems="${problems}\`$tok\` leaves the repository; "
                continue
            fi
            res="$(resolve_path "$repo" "$p" "")"
            case "$res" in
                tracked) artifacts=$((artifacts + 1)) ;;
                unavailable*) unav+=("$p|${res#unavailable }") ;;
                *) problems="${problems}\`$p\` is not tracked; " ;;
            esac
        done
    done

    if [ -n "$problems" ]; then
        cmd_fail="${cmd_fail}${where} Command \`$norm\`: ${problems%; }; "
    elif [ "${#unav[@]}" -gt 0 ]; then
        for p in "${unav[@]}"; do
            unavail_lines+=("${p%%|*} — submodule ${p#*|} is not initialized in this checkout, so the artifact cannot be read here (${where} Command \`$norm\`)")
        done
    elif [ "$artifacts" -eq 0 ]; then
        cmd_fail="${cmd_fail}${where} Command \`$norm\` names no repository artifact — no Makefile target, tracked path, or workflow step resolves, and a bare tool invocation cannot be checked; "
    else
        cmd_ok="${cmd_ok}\`$norm\`; "
    fi
}

while IFS=$'\t' read -r kind a b c; do
    [ "$kind" = C ] || continue
    resolve_command "$a" "$b" "$c"
done <"$work/records"

manual_note=""
[ "$manual" -eq 0 ] || manual_note=" ($manual manual requirement(s) with Command: none)"

# --- report, clause by clause --------------------------------------------------
for n in 1 2 3 4 5 6 7 8 9; do
    if [ "$n" -eq 8 ]; then
        if [ -n "$cmd_fail" ]; then
            fail 8 "${cmd_fail%; }"
        elif [ "${#unavail_lines[@]}" -gt 0 ]; then
            for l in "${unavail_lines[@]}"; do
                printf 'unavailable %s\n' "$l"
                unavailable=$((unavailable + 1))
            done
        elif [ -n "$cmd_ok" ]; then
            pass 8 "declared command(s) resolve to tracked artifacts: ${cmd_ok%; }$manual_note"
        else
            pass 8 "no command to resolve$manual_note"
        fi
        continue
    fi
    problems="$(awk -F'\t' -v n="$n" '$1 == "F" && $2 == n { print $3 }' "$work/records")"
    if [ -n "$problems" ]; then
        fail "$n" "$(printf '%s' "$problems" | awk 'NR > 1 { printf "; " } { printf "%s", $0 }')"
    else
        pass "$n" "$(awk -F'\t' -v n="$n" '$1 == "O" && $2 == n { print $3 }' "$work/records")"
    fi
done

verdict conformant
