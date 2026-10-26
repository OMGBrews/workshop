#!/usr/bin/env bash
# Compatibility helper for the separate audit-queue runner.
# Autonomous task execution is retired; audit-queue still links this path.
#
# Interactive `claude` does not exit on its own when it stops responding — it
# sits at the TUI prompt, and the loop runner (run.sh) blocks forever waiting
# for it. So a worker's final action is to run this script, which walks up
# the process tree from its own shell to the nearest `claude` ancestor and
# sends it SIGTERM.
#
# This lives in its own file (rather than inline in initial-prompt.md) so the
# worker runs it byte-for-byte instead of reproducing it from the prompt — a
# transcription slip in this script is silent or dangerous, and the worker may
# be reaching for it deep into a long context. The runner passes this script's
# absolute path to the worker via an env var; the prompt tells the worker to
# run `bash "$<RUNNER>_SELF_TERMINATE"`.
#
# The traversal is process-local: it starts from this script's own shell, so
# it can only ever reach the `claude` session that invoked it — never a
# sibling Claude elsewhere in the sandbox.
#
# Ancestor detection uses `readlink /proc/$PID/exe`, not `ps -o comm`. Under
# interactive `claude`, the TUI's comm is "claude"; but under `claude --bg`
# (Agent View, shipped 2026-05-11), the daemon execs the versioned binary
# directly so the worker's comm is the bare version (e.g. "2.1.150"). The
# exe symlink resolves to `/home/vscode/.local/share/claude/versions/<v>` in
# both modes (and to `/home/vscode/.local/bin/claude` when a PATH symlink is
# in play). Matching `/claude` in the exe path covers both. See the
# 2026-05-24 kaizen entry — the original comm walk silently no-op'd under
# `--bg`, the worker's turn ended without termination, and the audit-queue
# runner blocked forever in wait_for_bg_session.
#
# SIGTERM (not SIGKILL) is deliberate: it lets the Claude Code TUI restore the
# terminal cleanly. SIGKILL would leave the terminal in raw mode.

PID=$$
while [ "$PID" != "1" ]; do
  PID=$(ps -o ppid= "$PID" 2>/dev/null | tr -d ' ')
  [ -z "$PID" ] && break
  exe=$(readlink "/proc/$PID/exe" 2>/dev/null || true)
  case "$exe" in
    */claude|*/claude/*)
      kill -TERM "$PID"
      exit 0
      ;;
  esac
done

# Walked to the top without finding a Claude ancestor. Exit non-zero so the
# worker's last Bash tool_result surfaces the failure in the JSONL, instead
# of silently leaving the session idle until something else notices.
echo "self-terminate: no Claude ancestor found in process tree (started from PID $$)" >&2
exit 1
