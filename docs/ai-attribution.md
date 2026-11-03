# AI attribution checks

Workshop rejects explicit assistant credit in local commit messages and supported
pull-request commands. Ordinary discussion of AI tools and human co-authors is
allowed. These checks provide local feedback; GitHub does not enforce them.

## Adopt the commit hook

After updating your Workshop checkout, run the normal adoption command from
the consuming repository:

```bash
bash workshop/Tools/sync-skill-symlinks.sh .
```

This configures `core.hooksPath` to Workshop's hooks directory, including
`commit-msg`. Python 3 and Git are required. The hook reads the message file,
refuses explicit assistant credit, and explains which line to remove. It never
rewrites the message. The detector lives in `Tools/check-ai-attribution.py` and
is shared with the PR check.

Before updating an existing mount, inspect its `Tools/hooks/commit-msg` if it
exists: an ignored foreign hook may occupy that name. Preserve it and arrange
composition explicitly before checkout. The adoption helper also reports
collisions with foreign commit hooks and preserves the existing configuration;
resolve those warnings before claiming adoption. `core.hooksPath` is exclusive,
so other hook installers need deliberate composition too.

Both checks are enabled by default. To opt out in a repository:

```bash
git config --local workshop.blockAIAttribution false
```

Set it to `true` or remove the key to restore enforcement. The PR predicate
resolves the setting using the hook input's working directory and supported
literal `cd` commands. Do not treat an opt-out as a global policy change.

## Install the Claude PR adapter

Merge this entry into `.claude/settings.json` under `hooks.PreToolUse`,
preserving other entries. Adjust `workshop/` for your mount path:

```json
{
  "matcher": "Bash",
  "hooks": [
    {
      "type": "command",
      "command": "bash \"$CLAUDE_PROJECT_DIR/workshop/Tools/claude-attribution-guard.sh\"",
      "timeout": 10
    }
  ]
}
```

The adapter uses the [Claude hook input and decision format](https://code.claude.com/docs/en/hooks).
Only a positive attribution verdict produces a denial. Invalid input,
missing dependencies, and indeterminate commands allow the operation.
The reusable predicate can also run outside Claude:

```bash
python3 workshop/Tools/check-ai-attribution.py command "gh pr create --title 'Fix parser' --body 'Details'"
```

Exit 0 means inspected and allowed, 1 means explicit credit detected, and 2
means indeterminate. Callers should deny only 1 for this best-effort PR policy.

Supported forms are literal `gh pr create` and `gh pr edit` with `--title`/`-t`,
`--body`/`-b`, or existing readable `--body-file`/`-F` paths, including long
options with `=`. Literal `cd PATH && gh ...` uses PATH's repository policy.
Attribution patterns cover assistant co-author identities and standalone
“Generated with”, “Written by”, “Authored by”, “Created by”, “Co-authored by”,
and “Assisted by” credit lines naming Claude, Codex, Copilot, or Gemini,
including the common linked Claude Code footer. Human co-author names are
preserved, including names that contain an assistant's name.

## Coverage limits and container defaults

Unsupported wrappers, remote repository selectors, dollar or backtick syntax
(including quoted literal occurrences), pipelines,
redirections, runtime-generated files, stdin body files, and unavailable files
are allowed without a reliable inspection. The predicate never executes shell
text. Browser publishing, other APIs, other harnesses without an adapter, and
Git hook bypasses such as `--no-verify` remain outside this coverage. Installing
the commit hook does not install the Claude adapter.

The devcontainer kit seeds missing Claude `attribution.commit` and
`attribution.pr` fields with empty strings. Explicit existing preferences and
unrelated settings survive reruns; an intentional cleanup of existing settings
is a separate operation. See [Claude settings scopes](https://code.claude.com/docs/en/settings)
when inspecting repository, local, user, and managed overrides.
