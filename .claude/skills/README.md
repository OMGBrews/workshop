# Skills — the Claude Code bridge

Every entry beside this file is a symlink, and this folder holds no skills of
its own. The real skill directories live at `.agents/skills/<name>/` in the
repository root — the Agent Skills open standard's discovery path, which every
harness scans. `.claude/skills/` bridges to it with one
`<name> -> ../../.agents/skills/<name>` link per skill, so Claude Code and every
other harness run the same skill from one source.

## Author skills in `.agents/skills/`, never here

A real skill directory under `.claude/skills/` is a skill only one harness can
run. Since skills are where our process lives, that is the most expensive
mistake on this surface, and `Tools/check-agent-surfaces.sh` check 8 fails on it
by design. The rule and its rationale are
[surface 2 of the harness-agnostic standard](../../docs/harness-agnostic-repos.md).

## This repository is the source, not a consumer

Workshop *is* the shared tree, so `Tools/sync-skill-symlinks.sh` refuses to run
against this root — every skill would be linked onto itself. Maintain the links
here by hand when adding or renaming a skill:

```bash
ln -s ../../.agents/skills/<name> .claude/skills/<name>
```

Consuming repositories mount this tree and generate both surfaces from it,
including their own copy of this README, which the script writes and rewrites.
The version you are reading is the one exception, maintained here by hand; the
generated text lives in `Tools/sync-skill-symlinks.sh`.
