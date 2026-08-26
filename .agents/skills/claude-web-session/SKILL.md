---
name: claude-web-session
description: Inspect and validate a project's repository-owned Claude Code Web environment declaration, answer which environment and repositories a session needs, or render its archived setup script. Use for Claude Code Web launch configuration and readiness questions; external environment changes and session launches remain separately authorized actions.
---

# Claude Web Session

Use the project's fixed `docs/work/claude-code-web.md` declaration instead of a
fleet inventory or remembered environment name.

## Inspect

Resolve the current repository root, then resolve this skill's physical
directory (following a `.claude/skills/` bridge symlink when invoked there).
The shared tool is `../../../Tools/claude-code-web.py` from that physical
directory.

Run both commands from the project repository root:

```bash
python3 <workshop-root>/Tools/claude-code-web.py validate .
python3 <workshop-root>/Tools/claude-code-web.py show .
```

Stop on a validation error and report its diagnostic. Do not fall back to an HQ
inventory, `.claude/settings.json` alone, or a guessed environment.

For launch questions, report:

- the declared availability;
- the environment name and ID when configured;
- the primary repository;
- the always-attached additional repositories; and
- any task-specific repository attachment that the user's task independently
  requires. A parent in `docs/work/consumed-by.md` is shipping-only unless the
  task includes its pointer update; a child in `.gitmodules` is not automatically
  an attached repository.

If availability is `not-configured` or `unsupported`, report the declared reason
and refuse to launch. The negative state is the answer, not permission to choose
another environment.

## Render setup

When the user asks for the archived setup script, run:

```bash
python3 <workshop-root>/Tools/claude-code-web.py render-setup .
```

Return its stdout exactly when verbatim output was requested. It contains no
secret values; secret entries in the declaration record names and requirements
only.

## External actions

Validation, inspection, and rendering are local read-only actions. Do not create,
change, or reconcile a live Claude environment, and do not launch a Web session,
unless the user explicitly authorizes that external action. Before an authorized
action, show the validated environment and repository set that will be used.

This skill does not invent an external apply or launch mechanism. If no callable
Claude Code Web integration is available, return the validated configuration and
say that the requested external action is unavailable from the current session.
