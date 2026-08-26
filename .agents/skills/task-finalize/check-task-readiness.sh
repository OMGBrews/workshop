#!/usr/bin/env bash
# check-task-readiness.sh — one mechanical readiness verdict for task briefs.
#
# Default usage prints PASS/FAIL for readiness rules 1–8.  The explicit
# --conformance mode reuses the document-format parser for
# Tools/check-docs-work-conformance.sh: human drafts do not need the complete
# handoff verdict, while finalized and queued briefs additionally need a usable
# finalized-at.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage:
  bash check-task-readiness.sh <task-file>
  bash check-task-readiness.sh --conformance <task-file> <human|finalized>
EOF
}

mode="readiness"
policy=""
if [ "$#" -eq 1 ]; then
    task_argument="$1"
elif [ "$#" -eq 3 ] && [ "$1" = "--conformance" ]; then
    mode="conformance"
    task_argument="$2"
    policy="$3"
    case "$policy" in
        human | finalized | queued) ;;
        *)
            usage
            echo "invalid conformance policy '$policy' (expected human or finalized)" >&2
            exit 2
            ;;
    esac
else
    usage
    exit 2
fi

if ! task_file="$(readlink -f -- "$task_argument")"; then
    echo "cannot resolve task file '$task_argument'" >&2
    exit 2
fi
if [ ! -f "$task_file" ]; then
    echo "task file '$task_argument' is not a regular file" >&2
    exit 2
fi
if ! task_repo="$(git -C "$(dirname "$task_file")" rev-parse --show-toplevel 2>/dev/null)"; then
    echo "task file '$task_file' is not inside a Git worktree" >&2
    exit 2
fi
task_repo="$(cd -P "$task_repo" && pwd)"

# Parse frontmatter and the task-format sections once.  Every emitted value is
# a tab-separated scalar, so the Bash half can use the same parse for the full
# readiness verdict and conformance's narrower format contract.
declare -a dependencies=()
frontmatter_start=0
frontmatter_closed=0
status=""
status_count=0
effort=""
effort_count=0
priority=""
priority_count=0
dependencies_count=0
dependencies_syntax=0
dependencies_empty_item=0
dependencies_raw=""
finalized_at=""
finalized_at_count=0
goal_real=0
stopping_content=0
open_questions_content=0
ac_begin_count=0
ac_end_count=0
ac_order_valid=0
ac_real=0
ac_placeholder=0

if ! parsed_task="$(awk '
      function emit(key, value) { print key "\t" value }
      function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
      }
      function scalar(value) {
        value = trim(value)
        sub(/[[:space:]]+#.*$/, "", value)
        return trim(value)
      }
      # Return substantive text after removing HTML comments.  A task template
      # deliberately keeps required-section guidance in comments, which must
      # not satisfy a readiness rule.
      function without_comments(value,    start, finish, before, after) {
        while (1) {
          if (in_comment) {
            finish = index(value, "-->")
            if (finish == 0) return ""
            value = substr(value, finish + 3)
            in_comment = 0
          }
          start = index(value, "<!--")
          if (start == 0) break
          before = substr(value, 1, start - 1)
          after = substr(value, start + 4)
          finish = index(after, "-->")
          if (finish == 0) {
            value = before
            in_comment = 1
            break
          }
          value = before substr(after, finish + 3)
        }
        return trim(value)
      }
      function placeholder(value) {
        return value ~ /^<[^>]+>$/
      }
      function record_dependency(value) {
        value = scalar(value)
        if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
        value = trim(value)
        if (value == "") emit("DEPENDENCIES_EMPTY_ITEM", "1")
        else emit("DEPENDENCY", value)
      }
      NR == 1 {
        if ($0 == "---") { frontmatter_start = 1; in_frontmatter = 1 }
        else frontmatter_start = 0
        next
      }
      in_frontmatter {
        if ($0 ~ /^---[[:space:]]*$/) {
          in_frontmatter = 0
          frontmatter_closed = 1
          next
        }
        if (in_dependencies_block) {
          if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
            item = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", item)
            record_dependency(item)
            next
          }
          if ($0 ~ /^[[:space:]]*($|#)/) next
          in_dependencies_block = 0
        }
        if ($0 ~ /^status:[[:space:]]*/) {
          status_count++
          value = $0
          sub(/^status:[[:space:]]*/, "", value)
          status = scalar(value)
          next
        }
        if ($0 ~ /^effort:[[:space:]]*/) {
          effort_count++
          value = $0
          sub(/^effort:[[:space:]]*/, "", value)
          effort = scalar(value)
          next
        }
        if ($0 ~ /^priority:[[:space:]]*/) {
          priority_count++
          value = $0
          sub(/^priority:[[:space:]]*/, "", value)
          priority = scalar(value)
          next
        }
        if ($0 ~ /^dependencies:[[:space:]]*/) {
          dependencies_count++
          value = $0
          sub(/^dependencies:[[:space:]]*/, "", value)
          dependencies_raw = trim(value)
          if (value ~ /^\[[^]]*\][[:space:]]*(#.*)?$/) {
            sub(/^\[[[:space:]]*/, "", value)
            sub(/[[:space:]]*\][[:space:]]*(#.*)?$/, "", value)
            if (trim(value) != "") {
              count = split(value, parts, ",")
              for (item_index = 1; item_index <= count; item_index++) record_dependency(parts[item_index])
            }
          } else if (value ~ /^[[:space:]]*(#.*)?$/) {
            in_dependencies_block = 1
          } else {
            dependencies_syntax = 1
          }
          next
        }
        if ($0 ~ /^finalized-at:[[:space:]]*/) {
          finalized_at_count++
          value = $0
          sub(/^finalized-at:[[:space:]]*/, "", value)
          finalized_at = scalar(value)
          next
        }
        next
      }
      {
        if ($0 ~ /^<!-- AC:BEGIN([[:space:]]|--)/) {
          ac_begin_count++
          if (ac_begin_count == 1 && ac_end_count == 0 && !ac_open) ac_open = 1
          else ac_order_valid = 0
          next
        }
        if ($0 ~ /^<!-- AC:END([[:space:]]|--)/) {
          ac_end_count++
          if (ac_open && ac_end_count == 1) {
            ac_open = 0
            ac_closed_once = 1
          } else ac_order_valid = 0
          next
        }
        if (ac_open && $0 ~ /^- \[[ x~]\][[:space:]]*/) {
          value = $0
          sub(/^- \[[ x~]\][[:space:]]*/, "", value)
          value = without_comments(value)
          if (value == "" || placeholder(value)) emit("AC_PLACEHOLDER", "1")
          else emit("AC_REAL", "1")
          next
        }
        if ($0 ~ /^##[[:space:]]/) {
          section = ""
          if ($0 == "## Goal") section = "goal"
          else if ($0 == "## Stopping conditions") section = "stopping"
          else if ($0 == "## Open questions") section = "open-questions"
          next
        }
        if (section != "") {
          value = without_comments($0)
          if (value != "") {
            if (section == "goal") {
              if (!placeholder(value)) emit("GOAL_REAL", "1")
            } else if (section == "stopping") emit("STOPPING_CONTENT", "1")
            else if (section == "open-questions") emit("OPEN_QUESTIONS_CONTENT", "1")
          }
        }
      }
      END {
        if (ac_begin_count == 1 && ac_end_count == 1 && ac_closed_once && !ac_open) ac_order_valid = 1
        emit("FRONTMATTER_START", frontmatter_start + 0)
        emit("FRONTMATTER_CLOSED", frontmatter_closed + 0)
        emit("STATUS", status)
        emit("STATUS_COUNT", status_count + 0)
        emit("EFFORT", effort)
        emit("EFFORT_COUNT", effort_count + 0)
        emit("PRIORITY", priority)
        emit("PRIORITY_COUNT", priority_count + 0)
        emit("DEPENDENCIES_COUNT", dependencies_count + 0)
        emit("DEPENDENCIES_RAW", dependencies_raw)
        if (dependencies_syntax) emit("DEPENDENCIES_SYNTAX", "1")
        emit("FINALIZED_AT", finalized_at)
        emit("FINALIZED_AT_COUNT", finalized_at_count + 0)
        emit("AC_BEGIN_COUNT", ac_begin_count + 0)
        emit("AC_END_COUNT", ac_end_count + 0)
        emit("AC_ORDER_VALID", ac_order_valid + 0)
      }
    ' "$task_file")"; then
    echo "could not parse task file '$task_file'" >&2
    exit 2
fi

while IFS=$'\t' read -r key value; do
    case "$key" in
        FRONTMATTER_START) frontmatter_start="$value" ;;
        FRONTMATTER_CLOSED) frontmatter_closed="$value" ;;
        STATUS) status="$value" ;;
        STATUS_COUNT) status_count="$value" ;;
        EFFORT) effort="$value" ;;
        EFFORT_COUNT) effort_count="$value" ;;
        PRIORITY) priority="$value" ;;
        PRIORITY_COUNT) priority_count="$value" ;;
        DEPENDENCIES_COUNT) dependencies_count="$value" ;;
        DEPENDENCIES_SYNTAX) dependencies_syntax=1 ;;
        DEPENDENCIES_EMPTY_ITEM) dependencies_empty_item=1 ;;
        DEPENDENCIES_RAW) dependencies_raw="$value" ;;
        DEPENDENCY) dependencies+=("$value") ;;
        FINALIZED_AT) finalized_at="$value" ;;
        FINALIZED_AT_COUNT) finalized_at_count="$value" ;;
        GOAL_REAL) goal_real=$((goal_real + 1)) ;;
        STOPPING_CONTENT) stopping_content=$((stopping_content + 1)) ;;
        OPEN_QUESTIONS_CONTENT) open_questions_content=$((open_questions_content + 1)) ;;
        AC_BEGIN_COUNT) ac_begin_count="$value" ;;
        AC_END_COUNT) ac_end_count="$value" ;;
        AC_ORDER_VALID) ac_order_valid="$value" ;;
        AC_REAL) ac_real=$((ac_real + 1)) ;;
        AC_PLACEHOLDER) ac_placeholder=$((ac_placeholder + 1)) ;;
    esac
done <<<"$parsed_task"

field_issue() { # <field> <count> <value> <accepted-values>
    local field="$1" count="$2" value="$3" accepted="$4"
    if [ "$count" -eq 0 ]; then
        printf 'missing frontmatter field: %s' "$field"
    elif [ "$count" -ne 1 ]; then
        printf 'frontmatter field %s appears %s times' "$field" "$count"
    elif [ "$field" = "status" ] && [ "$value" = "done" ]; then
        printf 'status: done is rejected — completed tasks are deleted, never marked done'
    elif [[ " $accepted " != *" $value "* ]]; then
        printf '%s: invalid value "%s" (expected %s)' "$field" "$value" "$accepted"
    fi
    return 0
}

dependencies_issue() {
    local dependency
    if [ "$dependencies_count" -eq 0 ]; then
        printf 'missing frontmatter field: dependencies'
    elif [ "$dependencies_count" -ne 1 ]; then
        printf 'frontmatter field dependencies appears %s times' "$dependencies_count"
    elif [ "$dependencies_syntax" -ne 0 ]; then
        printf 'dependencies: must be a list, got "%s"' "$dependencies_raw"
    elif [ "$dependencies_empty_item" -ne 0 ]; then
        printf 'dependencies: list contains an empty item'
    else
        for dependency in "${dependencies[@]}"; do
            if ! [[ "$dependency" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
                printf 'dependencies: invalid task slug "%s"' "$dependency"
                return 0
            fi
        done
    fi
    return 0
}

finalized_at_issue() { # <required: 0|1> <check-commit: 0|1>
    local required="$1" check_commit="$2"
    if [ "$finalized_at_count" -eq 0 ]; then
        if [ "$required" -eq 1 ]; then
            printf 'missing finalized-at — finalized placement requires a verified brief'
        fi
    elif [ "$finalized_at_count" -ne 1 ]; then
        printf 'frontmatter field finalized-at appears %s times' "$finalized_at_count"
    elif ! [[ "$finalized_at" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'finalized-at is not a 40-hex commit SHA: %s' "$finalized_at"
    elif [ "$check_commit" -eq 1 ] && ! git -C "$task_repo" cat-file -e "$finalized_at^{commit}" 2>/dev/null; then
        printf 'finalized-at %s does not name a commit in this repo' "$finalized_at"
    fi
    return 0
}

sentinels_issue() {
    if [ "$ac_begin_count" -eq 0 ]; then
        printf 'missing AC:BEGIN sentinel — the task skills parse the acceptance list between the sentinels'
    elif [ "$ac_end_count" -eq 0 ]; then
        printf 'missing AC:END sentinel'
    elif [ "$ac_order_valid" -ne 1 ]; then
        printf 'AC sentinels are misordered or repeated — require one anchored AC:BEGIN before one AC:END'
    elif [ "$ac_real" -eq 0 ]; then
        printf 'no real checkbox items between the AC sentinels — the acceptance list is empty or holds only placeholders'
    fi
    return 0
}

if [ "$mode" = "conformance" ]; then
    conformance_failures=0
    format_fail() {
        printf '%s\n' "$1"
        conformance_failures=$((conformance_failures + 1))
    }

    if [ "$frontmatter_start" -ne 1 ]; then
        format_fail "file does not open with a --- frontmatter delimiter"
    elif [ "$frontmatter_closed" -ne 1 ]; then
        format_fail "frontmatter is not closed by a --- line"
    fi

    issue="$(field_issue status "$status_count" "$status" "not-started in-progress blocked")"
    [ -z "$issue" ] || format_fail "$issue"
    issue="$(field_issue effort "$effort_count" "$effort" "small medium large")"
    [ -z "$issue" ] || format_fail "$issue"
    issue="$(field_issue priority "$priority_count" "$priority" "high medium low")"
    [ -z "$issue" ] || format_fail "$issue"
    issue="$(dependencies_issue)"
    [ -z "$issue" ] || format_fail "$issue"

    if [ "$policy" = "finalized" ] || [ "$policy" = "queued" ]; then
        issue="$(finalized_at_issue 1 1)"
    else
        issue="$(finalized_at_issue 0 0)"
    fi
    [ -z "$issue" ] || format_fail "$issue"

    issue="$(sentinels_issue)"
    [ -z "$issue" ] || format_fail "$issue"

    if [ "$conformance_failures" -ne 0 ]; then
        exit 1
    fi
    exit 0
fi

pass_rule() { printf 'PASS %s %s\n' "$1" "$2"; }
fail_rule() {
    printf 'FAIL %s %s\n' "$1" "$2"
    readiness_failures=$((readiness_failures + 1))
}
warn_rule() { printf 'WARN %s %s\n' "$1" "$2"; }

readiness_failures=0

if [ "$goal_real" -gt 0 ]; then
    pass_rule 1 "Goal section is present and substantive"
else
    fail_rule 1 "Goal section is missing, empty, or a placeholder"
fi

issue="$(sentinels_issue)"
if [ -z "$issue" ]; then
    pass_rule 2 "Acceptance criteria have one ordered sentinel pair and $ac_real real checkbox item(s)"
else
    fail_rule 2 "$issue"
fi

if [ "$stopping_content" -gt 0 ]; then
    pass_rule 3 "Stopping conditions are present and substantive"
else
    fail_rule 3 "Stopping conditions are missing or empty"
fi

issue="$(field_issue status "$status_count" "$status" "not-started in-progress blocked")"
if [ -z "$issue" ]; then
    pass_rule 4 "status is '$status'"
else
    fail_rule 4 "$issue"
fi

issue="$(field_issue effort "$effort_count" "$effort" "small medium large")"
if [ -z "$issue" ]; then
    pass_rule 5 "effort is '$effort'"
else
    fail_rule 5 "$issue"
fi

if [ "$open_questions_content" -eq 0 ]; then
    pass_rule 6 "Open questions are absent or contain comments only"
else
    fail_rule 6 "Open questions still contain substantive text"
fi

priority_issue="$(field_issue priority "$priority_count" "$priority" "high medium low")"
dependencies_problem="$(dependencies_issue)"
if [ -n "$priority_issue" ] || [ -n "$dependencies_problem" ]; then
    issue="$priority_issue"
    if [ -n "$issue" ] && [ -n "$dependencies_problem" ]; then issue="$issue; $dependencies_problem"
    elif [ -z "$issue" ]; then issue="$dependencies_problem"
    fi
    fail_rule 7 "$issue"
else
    pass_rule 7 "priority is '$priority' and dependencies are well-formed"
fi

issue="$(finalized_at_issue 1 1)"
if [ -z "$issue" ]; then
    pass_rule 8 "finalized-at names a commit in this task file's worktree"
else
    fail_rule 8 "$issue"
fi

# A valid dependency can refer to completed work (whose brief was deleted) or
# to a typo.  This checker deliberately warns instead of deciding that policy;
# task-finalize's verification phase retains that stronger disambiguation.
tasks_root="$task_repo/docs/work/tasks"
for dependency in "${dependencies[@]}"; do
    if ! [[ "$dependency" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
        continue
    fi
    matching_task=""
    if [ -n "$tasks_root" ]; then
        matching_task="$(find "$tasks_root" -type f -name "$dependency.md" -print -quit)"
    fi
    if [ -z "$matching_task" ]; then
        warn_rule 7 "dependency '$dependency' matches no current task file"
    fi
done

if [ "$readiness_failures" -ne 0 ]; then
    exit 1
fi
