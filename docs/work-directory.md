# Work-directory contract

This document defines the portable `docs/work/` structure used by Workshop
skills and checks. Read it when a repository adopts the shared task, kaizen,
or audit machinery, or when changing a tool that reads those records.

## Contract

`docs/work/` is machine-readable repository state, not a general-purpose
documentation folder. A consumer that enables a Workshop capability provides
the directories and files that capability names, and keeps repository-specific
policy beside them rather than baking it into a shared tool.

| Path | Purpose | Owner |
|------|---------|-------|
| `docs/work/tasks/` | Task briefs and their lifecycle buckets | Task skills and the repository maintainer |
| `docs/work/definition-of-done.md` | Repository-required verification evidence | Repository maintainer |
| `docs/work/kaizen/` | Process-friction journal, patterns, and problems | Kaizen skills and the repository maintainer |
| `docs/work/audits/` | Audit tracker state when audit skills are used | Audit skills |
| `docs/work/claude-code-web.md` | Desired cloud-session declaration when configured | Repository maintainer |

Each capability is optional unless another documented repository contract
requires it. Shared code receives the relevant work-directory and registry
paths from its caller; it never infers a particular fleet, account, or private
workspace layout from a fixed absolute path.

## Consumer guidance

Start with the skill or checker that owns the capability: it creates or
validates its own shape. Keep repository decisions, rollout records, and
consumer inventories outside this generic contract. A private control plane may
add stricter policy without making those private paths an input to Workshop.

## See also

- [Task skill](../.agents/skills/task-create/SKILL.md)
- [Definition of done](definition-of-done.md)
- [Kaizen guide](kaizen-guide.md)
