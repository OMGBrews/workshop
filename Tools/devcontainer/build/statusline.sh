#!/bin/bash
# Claude Code status line — two rows:
#   row 1: repo, branch, uncommitted/unpushed counts | model, window, effort
#   row 2: context-fill bar, rate limits (5h/7d), session cost
#
# Managed by Workshop (Tools/devcontainer/build/statusline.sh). Local edits are
# overwritten on the next container rebuild — change it upstream in Workshop.
#
# This is the source of truth. setup.sh installs a copy of it to
# ~/.claude/statusline.sh from beside itself, so every Dockerfile that COPYs
# setup.sh must COPY this file next to it.

input=$(cat)

# ---- one jq pass; every field may be null before the first API response -------
# Fields are joined with US (\x1f), not tab: tab is IFS-whitespace, so bash would
# collapse runs of it and an empty field (e.g. absent .effort) would shift every
# later field left by one.
IFS=$'\x1f' read -r MODEL WIN_SIZE EFFORT CTX_PCT IN_TOK OUT_TOK \
                    RL5 RL5_RESET RL7 CWD PROJDIR REPO AGENT TRANSCRIPT FAST < <(
  printf '%s' "$input" | jq -r '
    [ .model.display_name                     // "?"
    , .context_window.context_window_size     // 0
    , .effort.level                           // ""
    , .context_window.used_percentage         // 0
    , .context_window.total_input_tokens      // 0
    , .context_window.total_output_tokens     // 0
    , .rate_limits.five_hour.used_percentage  // -1
    , .rate_limits.five_hour.resets_at        // 0
    , .rate_limits.seven_day.used_percentage  // -1
    , .workspace.current_dir                  // "."
    , .workspace.project_dir                  // ""
    , .workspace.repo.name                    // ""
    , .agent.name                             // ""
    , .transcript_path                        // ""
    , .fast_mode                              // false
    ] | map(tostring) | join("\u001f")'
)

R=$'\033[0m'; DIM=$'\033[2m'; B=$'\033[1m'
GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYA=$'\033[36m'; MAG=$'\033[35m'

# ---- helpers -----------------------------------------------------------------
fmt_tokens() {  # 312000 -> 312k ; 1000000 -> 1.0M
  awk -v n="$1" 'BEGIN{
    if (n >= 1000000) printf "%.1fM", n/1000000;
    else if (n >= 1000) printf "%dk", n/1000;
    else printf "%d", n;
  }'
}
pct_color() {   # green < 50, yellow 50-79, red >= 80
  awk -v p="$1" -v g="$GRN" -v y="$YEL" -v r="$RED" 'BEGIN{
    print (p >= 80) ? r : (p >= 50) ? y : g }'
}

# ---- git, cached (this script runs after every turn; git status is slow) ------
cache="${TMPDIR:-/tmp}/.ccstatus-git-$(printf '%s' "$CWD" | cksum | cut -d' ' -f1)"
if [ -z "$(find "$cache" -newermt '-5 seconds' 2>/dev/null)" ]; then
  {
    if git -C "$CWD" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      # EVERY command in this block must emit exactly one line. The `read`s below
      # are positional, so anything that prints nothing — or twice — silently
      # shifts every later field. That is exactly how the ahead-count was lost
      # before 2026-07-26: `grep -c ''` prints 0 *and* exits 1 on empty input, so
      # a `|| echo 0` fallback appended a fourth line and pushed the real count
      # off the end. The `|| echo` guards here are safe only because these
      # commands print nothing when they fail; never add one to a command that
      # prints on failure, and never guard the `grep -c` at all.
      git -C "$CWD" --no-optional-locks rev-parse --show-toplevel 2>/dev/null || echo
      # the project repo's toplevel, for the same-repo test in row 1. Compared as
      # toplevels, never as raw paths: project_dir is where Claude Code was
      # LAUNCHED, which is often a subdirectory of the repo rather than its root.
      git -C "$PROJDIR" --no-optional-locks rev-parse --show-toplevel 2>/dev/null || echo
      git -C "$CWD" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
        || git -C "$CWD" --no-optional-locks rev-parse --short HEAD 2>/dev/null || echo
      # every uncommitted change: staged, unstaged, and untracked
      git -C "$CWD" --no-optional-locks status --porcelain 2>/dev/null | grep -c ''
      # commits ahead of upstream (0 when no upstream is configured)
      git -C "$CWD" --no-optional-locks rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0
    fi
  # $$ in the temp name: the cache path is keyed on $CWD alone, so two sessions
  # in the same directory shared one .tmp and could interleave into it. The mv is
  # atomic, so readers never saw a torn file — but a garbled result could still be
  # promoted and then served for its whole 5-second life.
  } > "$cache.$$.tmp" 2>/dev/null && mv -f "$cache.$$.tmp" "$cache" 2>/dev/null
fi
{ read -r TOPLEVEL; read -r PROJTOP; read -r BRANCH; read -r DIRTY; read -r AHEAD; } < "$cache" 2>/dev/null
: "${TOPLEVEL:=}" "${PROJTOP:=}" "${BRANCH:=}" "${DIRTY:=0}" "${AHEAD:=0}"

# ================================ row 1 =======================================
# Name the repo the counts actually describe. `.workspace.repo.name` is the
# PROJECT repo, derived from project_dir — but branch/dirty/ahead are all read
# from current_dir, and in a workspace built out of submodules those are
# routinely different repos. Sitting in /workspace/devtools with
# project_dir=/workspace, row 1 rendered "hq ⎇ main ✎1" while the branch and that
# one modified file belonged to devtools. A label that names a different repo
# than its own numbers is worse than no label.
#
# Confirmed empirically: repo.name keys off project_dir, not cwd — the captured
# payload said "hq" while cwd was /workspace/devtools, itself a clone with its own
# origin remote. So the test is whether cwd's repo IS the project repo.
#
# Compare git TOPLEVELS, not raw paths. project_dir is where Claude Code was
# launched and is frequently a subdirectory of the repo, so `$TOPLEVEL != $PROJDIR`
# would call an ordinary `cd docs/` session "nested" and relabel it. Toplevels also
# arrive as resolved physical paths on both sides, which sidesteps symlinks.
#
# Inside a genuinely different repo, the directory name wins. Otherwise keep the
# payload's name: it is the repo's real name, which the directory need not match
# (this workspace clones OMGBrewmaster/hq into /workspace, so a basename would say
# "workspace"). Fall back to a basename only when the payload offers nothing —
# workspace.repo is absent entirely in a repo with no origin remote.
if [ -n "$TOPLEVEL" ] && [ -n "$PROJTOP" ] && [ "$TOPLEVEL" != "$PROJTOP" ]; then
  REPO=$(basename "$TOPLEVEL")
fi
[ -n "$REPO" ] || REPO=$(basename "${TOPLEVEL:-$CWD}")
left="${B}${CYA}${REPO}${R}"; lplain="$REPO"
if [ -n "$BRANCH" ]; then
  left+=" ${DIM}⎇${R} ${CYA}${BRANCH}${R}"; lplain+=" ⎇ $BRANCH"
  [ "$DIRTY" -gt 0 ] 2>/dev/null && { left+=" ${YEL}✎${DIRTY}${R}"; lplain+=" ✎$DIRTY"; }
  [ "$AHEAD" -gt 0 ] 2>/dev/null && { left+=" ${MAG}↑${AHEAD}${R}"; lplain+=" ↑$AHEAD"; }
fi
# a subagent driving the turn is worth knowing about; it's normally invisible
if [ -n "$AGENT" ]; then
  left+=" ${DIM}·${R} ${MAG}⚙ ${AGENT}${R}"; lplain+=" · ⚙ $AGENT"
fi

right="${B}${MODEL}${R}"; rplain="$MODEL"
if [ "$WIN_SIZE" -gt 0 ] 2>/dev/null; then
  w=$(fmt_tokens "$WIN_SIZE"); right+=" ${DIM}· ${w}${R}"; rplain+=" · $w"
fi
[ -n "$EFFORT" ] && { right+=" ${DIM}· ${EFFORT}${R}"; rplain+=" · $EFFORT"; }

# ---- right-align row 1 -------------------------------------------------------
# COLUMNS is the width to align against (Claude Code sets it; tput can't see the
# terminal from here), but the gap is NOT COLUMNS - ${#lplain} - ${#rplain}:
#
#   1. ${#var} counts CHARACTERS; a terminal lays out CELLS. Every non-ASCII
#      glyph on this row (⎇ ✎ ↑ ⚙ ·) is East-Asian *Ambiguous* width, which many
#      terminals draw two cells wide. Counting them as one under-measures both
#      groups, over-pads the gap, and pushes the tail of the right group past the
#      right edge — the "Opus 5 · 1.0M · ..." truncation this used to produce.
#      Two is the safe direction to be wrong in: where a terminal draws them
#      narrow the row merely sits a cell or two shy of flush, which reads fine.
#   2. Claude Code draws the status line inside its own frame, so the usable
#      width is a little under COLUMNS — a row of exactly COLUMNS cells already
#      overflows. RESERVE holds it off the edge; raise it if a frame grows.
RESERVE=${CC_STATUSLINE_RESERVE:-2}
cells() {  # display width of $1, ambiguous-width glyphs counted as two cells
  local narrow=${1//[⎇✎↑⚙·]/}
  echo $(( ${#1} + ${#1} - ${#narrow} ))
}
gap=$(( ${COLUMNS:-0} - RESERVE - $(cells "$lplain") - $(cells "$rplain") ))
if [ "$gap" -ge 2 ]; then
  printf '%s%*s%s\n' "$left" "$gap" "" "$right"
else
  printf '%s %s·%s %s\n' "$left" "$DIM" "$R" "$right"
fi

# ================================ row 2 =======================================
# used_percentage is authoritative for context state (per Claude Code docs);
# the token counts are only for display.
pct=${CTX_PCT%.*}; [ -n "$pct" ] || pct=0
filled=$(( (pct + 5) / 10 )); [ "$filled" -gt 10 ] && filled=10
[ "$filled" -lt 0 ] && filled=0
# built with a loop, not `printf '█%.0s' $(seq 1 $filled)`: printf runs its format
# once even with zero args, which yields an 11-cell bar at 0% and at 100%.
bar=""
for ((i = 0; i < 10; i++)); do
  if [ "$i" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi
done
c=$(pct_color "$pct")

row2="${DIM}ctx${R} ${c}${bar}${R} ${c}${B}${pct}%${R}"
used=$(( IN_TOK + OUT_TOK ))
if [ "$used" -gt 0 ] && [ "$WIN_SIZE" -gt 0 ] 2>/dev/null; then
  row2+=" ${DIM}$(fmt_tokens "$used")/$(fmt_tokens "$WIN_SIZE")${R}"
fi

# rate limits: percentage always; add a reset countdown once it's worth acting on
add_limit() { # $1 label  $2 pct  $3 resets_at(epoch, 0=none)
  [ "${2%.*}" -lt 0 ] 2>/dev/null && return
  local p=${2%.*} lc; lc=$(pct_color "$p")
  row2+=" ${DIM}·${R} ${DIM}$1${R} ${lc}${p}%${R}"
  if [ "$p" -ge 60 ] && [ "${3:-0}" -gt 0 ] 2>/dev/null; then
    # resets_at is Unix epoch seconds — confirmed against the documented schema
    # (code.claude.com/docs/en/statusline) and a live payload, 2026-07-26. The
    # clamp stays as a guard on the arithmetic, not on the unit: a bare `> 0` test
    # let any out-of-range value render as garbage (a far-future one printed
    # ⟳2281920h35m). A rolling window cannot reset further out than its own
    # length, so bound it by that and drop the segment rather than print a number
    # nobody can act on. Note rate_limits is absent entirely for non-subscribers
    # and each window may be absent independently; the jq defaults handle that.
    local secs=$(( $3 - $(date +%s) )) max
    case $1 in
      5h) max=$(( 5 * 3600 )) ;;
      7d) max=$(( 7 * 86400 )) ;;
      *)  max=$(( 7 * 86400 )) ;;
    esac
    max=$(( max + 600 ))  # slack for clock skew between us and the API
    [ "$secs" -gt 0 ] && [ "$secs" -le "$max" ] \
      && row2+=" ${lc}⟳$(( secs / 3600 ))h$(( secs % 3600 / 60 ))m${R}"
  fi
}
add_limit 5h "$RL5" "$RL5_RESET"
add_limit 7d "$RL7" 0

# ---- warnings: collected separately, rendered FIRST ---------------------------
# Row 2 has no width budget, so an over-long row is clipped from the right. These
# warnings used to be appended last, which made the single most important thing on
# the bar the first thing to fall off: a hot row (97% ctx, 5h at 100%) measures
# ~102 cells and so overflows an 80-column terminal by 22. Whatever else gets cut,
# the money must survive — so it leads, and the token counts take the truncation.
warn=""
add_warn() { warn+="${warn:+ }$1"; }

# ---- metered spend: the ONLY money on a Pro/Max plan ---------------------------
#
# On a subscription, plan usage costs nothing per token — so no dollar figure is
# shown in the normal case. Money appears only when usage credits are actually
# being spent, and this is the loudest thing on the line when it happens.
#
# Fast mode (`/fast`) is the door most people walk through without noticing: it
# "draws directly from usage credits, even if you have remaining usage on your
# plan ... charged at the fast mode rate from the first token" (Claude Code docs),
# and it PERSISTS ACROSS SESSIONS by default. The API stamps every message with
# usage.speed, so the transcript is an exact record of which tokens were billed.
#
# Fast-mode rates per MTok in/out, from code.claude.com/docs/en/fast-mode
# (checked 2026-07-26): Opus 5 = $10/$50, Opus 4.8 = $10/$50, flat across the full
# 1M window. Opus 4.7 = $30/$150 is kept for HISTORICAL transcripts only — fast
# mode on 4.7 was deprecated 2026-06-25 and removed 2026-07-24, and the API now
# rejects those requests outright. Cache multipliers on input: read 0.1x, 5m write
# 1.25x, 1h write 2.0x. Standard-speed messages are in-plan and cost nothing.
#
# Every rate is MATCHED EXPLICITLY and an unrecognized model is counted as
# unpriced, never defaulted. The old `else {i:10,o:50}` quietly applied 4.8's rate
# to every model it had never heard of — including any model released after the
# table was written — and rendered the guess as a definite-looking `~$12.34`. A
# figure whose whole job is to warn about real money must not be invented; when
# the rate is unknown, say so and show the exposure instead. Add a model here only
# with a cited rate, never by widening the fallback.
#
# Emits three fields: <fast messages> <priced USD> <unpriced messages>.
credit_spend() {
  [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || { echo "0 0 0"; return; }
  # cache on transcript byte size — the file only ever grows, so an unchanged
  # size means an unchanged answer. Keeps a long session off a repeated full scan.
  local sz cache
  sz=$(wc -c < "$TRANSCRIPT" 2>/dev/null || echo 0)
  cache="${TMPDIR:-/tmp}/.ccstatus-credits-$(printf '%s' "$TRANSCRIPT" | cksum | cut -d' ' -f1)"
  if [ -r "$cache" ]; then
    local csz rest
    read -r csz rest < "$cache"
    [ "$csz" = "$sz" ] && { echo "$rest"; return; }
  fi
  local out
  out=$(jq -s -r '
    [ .[] | select(.message.usage.speed == "fast") | .message ] as $fast
    | [ $fast[]
        | . as $m
        | (if   (($m.model // "") | test("opus-5"))   then {i:10,o:50}
           elif (($m.model // "") | test("opus-4-8")) then {i:10,o:50}
           elif (($m.model // "") | test("opus-4-7")) then {i:30,o:150}
           else null end) as $r
        | select($r != null)
        | $m.usage as $u
        | ( (($u.input_tokens // 0) * $r.i)
          + (($u.cache_creation.ephemeral_5m_input_tokens // 0) * $r.i * 1.25)
          + (($u.cache_creation.ephemeral_1h_input_tokens // 0) * $r.i * 2.0)
          + (($u.cache_read_input_tokens // 0) * $r.i * 0.1)
          + (($u.output_tokens // 0) * $r.o)
          ) / 1000000
      ] as $priced
    | "\($fast|length) \($priced|add // 0) \(($fast|length) - ($priced|length))"
    ' "$TRANSCRIPT" 2>/dev/null) || out="0 0 0"
  printf '%s %s\n' "$sz" "$out" > "$cache" 2>/dev/null
  echo "$out"
}
read -r FAST_MSGS CREDIT_USD UNPRICED <<< "$(credit_spend)"

if [ "${FAST_MSGS:-0}" -gt 0 ] 2>/dev/null; then
  # Real money has been spent. Say so unmissably, and mark it as an estimate —
  # the authoritative figure is Settings → Usage, not this line.
  if [ "${UNPRICED:-0}" -ge "${FAST_MSGS:-0}" ] 2>/dev/null; then
    # Nothing matched a known rate. Report the exposure, never a made-up total.
    add_warn "${RED}${B}↯ CREDITS — ${FAST_MSGS} msg, rate unknown${R}"
  elif [ "${UNPRICED:-0}" -gt 0 ] 2>/dev/null; then
    add_warn "${RED}${B}↯ CREDITS ~\$$(printf '%.2f' "$CREDIT_USD") +${UNPRICED} unpriced${R}"
  else
    add_warn "${RED}${B}↯ CREDITS ~\$$(printf '%.2f' "$CREDIT_USD")${R}"
  fi
elif [ "$FAST" = "true" ]; then
  # Fast mode armed but nothing billed yet — the next token starts charging.
  #
  # This reads the payload's own `.fast_mode` ("whether fast mode is enabled for
  # the session"), NOT `.fastMode` out of ~/.claude/settings.json as it used to.
  # The settings read was wrong in both directions. It saw only the user layer,
  # missing managed/project/local. Worse, the saved preference is not the session
  # state: `fastModePerSessionOptIn` resets it every session, and fast mode also
  # silently falls back to standard speed when usage credits run out, when the
  # fast-mode rate limit cools down, when the org has it disabled, when the
  # availability check can't reach api.anthropic.com, and under
  # CLAUDE_CODE_DISABLE_FAST_MODE=1. Every one of those made this warn about
  # spending that was not happening. The payload field is the session's truth.
  add_warn "${RED}${B}↯ FAST MODE — bills credits${R}"
fi

# The other door into metered spend: plan allowance exhausted. Past 100%, further
# usage bills usage credits (if they are turned on). No dollar figure is possible
# here — the payload carries no credit balance, and the Usage & Cost API is
# org-only — so this warns rather than counts.
for lim in "5h:$RL5" "7d:$RL7"; do
  p=${lim#*:}; p=${p%.*}
  [ "${p:-0}" -ge 100 ] 2>/dev/null && {
    add_warn "${RED}${B}⚠ ${lim%%:*} PLAN LIMIT — may bill credits${R}"; break; }
done

# NOTE: .cost.total_cost_usd is deliberately NOT shown. It is an API-equivalent
# estimate; the docs say Pro/Max "have usage included in their subscription, so the
# session cost figure isn't relevant for billing purposes." Showing it would put a
# number that looks like money next to one that is money.
# .exceeds_200k_tokens is likewise not shown: Opus 4.8 bills its full 1M window at
# flat rates, so 200k is not a cost event.

printf '%s\n' "${warn:+$warn ${DIM}·${R} }$row2"
