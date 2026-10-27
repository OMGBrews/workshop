# Cloud dispatch

The launch procedure shared by the three cloud dispatch skills: `problem-plan-cloud`,
`task-finalize-cloud`, and `task-implement-cloud`. It covers reading the records
the sessions will see, resolving where the sessions go and which route launches them,
finding sessions already at work, printing the plan, creating one Claude Code on the
web session per record, verifying each, and reporting. The skills run from a Claude
Code on the web session, which launches through the cloud session tools, or from a
local Claude Code session, which launches with `claude --cloud`. Read it from any of
those skills when a step says to; each skill owns its bucket, its gates, and the stage
instructions inside the prompt.

## What the three skills share

Each skill sends every eligible record in one bucket to its own cloud session, and
each session runs one stage skill on its record. The skills differ only in the rows
below.

| | `problem-plan-cloud` | `task-finalize-cloud` | `task-implement-cloud` |
|---|---|---|---|
| Stage skill each session runs | `problem-plan` | `task-finalize` | `task-implement` |
| Default bucket | `docs/work/problems/now/` | `docs/work/tasks/now/` | `docs/work/tasks/finalized/` |
| Session title | `Plan: <H1>` | `Finalize: <H1>` | `Implement: <H1>`, or `Implement (cloud part): <H1>` |
| Session tag | `problem-plan:<slug>` | `task-finalize:<slug>` | `task-implement:<slug>` |
| Each session stops at | the orientation card | the orientation card | the close-out question, or the resume point of a cloud part |

The tag is how a later run finds a session already at work on a record, so it is
exact: the stage skill's name, a colon, and the record's filename without `.md`. A
session launched from a local session carries no tags, so its title, exact as in the
table, is its marker.

## Authorization

Invoking a dispatch skill authorizes creating one cloud session per record its
printed plan names, in the environment this repository declares, and nothing else.
On the CLI route that is one `claude --cloud` launch per record. The dispatcher
writes nothing in the working tree, commits nothing, and pushes nothing. Each session spends the owner's cloud usage, so the plan is printed before any
launch, and nothing is launched that the plan did not name. The planning, finalizing,
or implementing happens in the sessions, between the owner and each one.

Every dispatch skill takes these arguments, in any order, beside its own:

- one or more record slugs or filenames, which narrow the batch to those records in
  the skill's bucket; this is how a record whose session failed or was archived is
  sent again;
- `dry-run`, which stops after the plan.

## 1. Read what the sessions will read

A dispatched session clones the repository's default branch, not this checkout's
branch. Read the records, the declaration, and the policies from that branch, so
the gates judge what the sessions will see:

```bash
git fetch origin
default="$(git symbolic-ref --short refs/remotes/origin/HEAD)"   # for example origin/main
snapshot="<scratch directory>/dispatch-snapshot"
rm -rf "$snapshot" && mkdir -p "$snapshot"
set -o pipefail
git archive "$default" docs/work <further authority paths> | tar -x -C "$snapshot"
echo "EXIT=$?"
git rev-parse "$default"
```

`docs/work` holds the records, the declaration, the definition of done, and the ship
policies. `task-implement-cloud` also reads every further document the declaration
names as a capability authority, such as a test README that says which harnesses
run without a host; add those paths to the archive, and nothing else.

Check the fetch and the archive both exited 0; a failed fetch leaves a stale
snapshot, which is a stop, not a warning. Record the commit printed last: the plan
names it. Every later step reads records from `$snapshot`, and passes `$snapshot`
as the repository root to tools that take one. Then compare the snapshot with this
checkout:

```bash
git diff --stat "$default" -- docs/work
git status --porcelain -- docs/work
```

Any output is a difference between what this checkout shows and what the sessions
will start from. Name it in the plan, because a record changed only here, such as
a task not yet landed, is invisible to its session. Do not dispatch from the local
copy instead.

## 2. Resolve where the sessions go

Validate the declaration in this checkout, not in the snapshot: the validator also
compares the bootstrap scripts with the mounted Workshop templates, and a snapshot
carries neither the scripts nor the submodule. Then prove the default branch
declares the same configuration block, since that is the block the sessions start
with:

```bash
tree="$(dirname "$(readlink -f .agents/skills/problem-plan-cloud/cloud-dispatch.md)")/../../.."
python3 "$tree/Tools/claude-code-web.py" validate .
python3 "$tree/Tools/claude-code-web.py" show . --json
block() { sed -n '/WORKSHOP-CLOUD-SESSION:BEGIN/,/WORKSHOP-CLOUD-SESSION:END/p'; }
diff <(git show "$default":docs/work/claude-code-web.md | block) \
     <(block < docs/work/claude-code-web.md)
echo "DIFF_EXIT=$?"
```

The tool is resolved from this file's physical directory, per
[skill path resolution](../../../docs/skill-path-resolution.md), so the mount's
name never appears here. Stop on a validation error and report its diagnostic. `DIFF_EXIT` must be 0. Exit 1
means this checkout declares a different environment or repository from the one
the sessions would start with: stop and report the difference. Exit 2, or an empty
block on either side, means the comparison could not be made, which is also a stop. `availability` must be
`configured`; `not-configured` or `unsupported` is the answer, with its declared
reason, and nothing launches. Take from the declaration:

| Field | Becomes |
|---|---|
| `environment.id` | `environment_id` of every session |
| `primaryRepository` | `source_url`: `https://github.com/<primaryRepository>` |

Pass both explicitly on every launch, on either route; never rely on a new session
inheriting them, and never substitute a remembered environment or
`.claude/settings.json`.

Then pick the launch route, in this order, and name it in the plan:

1. **Cloud route.** The claude-code-remote MCP server's `create_session` and
   `get_session` are in this session's tool list, as they are in a Claude Code on
   the web session.
2. **CLI route.** They are absent, and this machine can start a cloud session with
   `claude --cloud`: `claude auth status` prints `"loggedIn": true` with
   `"authMethod": "claude.ai"`, and `script --version` names util-linux. This is the
   route of a local Claude Code session.
3. **Render-only.** Neither. The run still inventories, gates, and prints the plan,
   then prints every prompt from step 5 in full for the owner to start by hand at
   claude.ai/code, and says that launching is unavailable from this session.

On the cloud route, call `get_session` with no argument for this session's own ID,
environment, model, and permission mode: the sessions inherit the last two, and when
this session's environment differs from the declared one the plan says so and the
declaration wins. `list_environments` is the read-only cross-check that the declared
ID still exists; a missing environment is a stop, reported with the names that do
exist, never a substitution. Step 3 also needs `list_sessions`.

On the CLI route there is no calling cloud session to inherit from, so the
dispatcher sets each value itself:

| Value | Source |
|---|---|
| This session's ID | `printenv CLAUDE_CODE_SESSION_ID`, for the prompt. Empty is a stop |
| Model | the model the owner named when invoking the skill, else the exact model ID this session runs as, passed as `--model` |
| Permission mode | the mode the owner named, else `auto`, passed as `--permission-mode`. Never `plan`, for the reason step 5 gives |
| Environment | the declared `environment.id`, passed in a `--settings` file as `remote.defaultEnvironmentId`. The CLI ranks flag settings above the project and local settings files; only managed policy outranks them |
| Repository and branch | this checkout's. The session starts from the remote copy of the current branch, without unpushed commits or uncommitted changes. So `git remote get-url origin` must name `primaryRepository`, and `git branch --show-current` must be the default branch from step 1; anything else is a stop |

This route has no environment listing to cross-check against. Each session reports
its own environment on its first turn, and step 6 reads it.

## 3. Find work already in flight

Two checks, run once for the whole batch. A record caught by either is skipped as
in flight, naming what caught it.

- **A live dispatched session.** A record is in flight when a session at work on it
  has a `status_bucket` of working, blocked, or review ready. Completed, failed, and
  archived sessions are not in flight. A session the cloud route started carries the
  record's tag from the table above. One the CLI route started carries no tags, so
  its marker is its title, exactly the skill's title for the record. A session
  started by hand, or before these skills existed, is found only when its title
  matches; the skills' own gates read the marks such sessions leave on the record.
  - *Cloud route.* Call `list_sessions` with `mine` set and a limit of 100, paging
    with `after_id` while `has_more` is true, up to five pages; a run that hits the
    bound says so. A page of 100 sessions runs to about 250 KB, so parse each page
    from the saved result for each session's `id`, `title`, `tags`, and
    `status_bucket` rather than reading it, and match each record by its tag or its
    exact title. The listing's own `tags` filter has answered "not currently
    available", so filter the saved pages instead.
  - *CLI route.* A local session has no tool that lists cloud sessions, so this half
    is unavailable for every record. The plan says so, and that the owner can look
    in the session list at claude.ai/code for a session already titled for a record
    before it goes out again.
- **An open pull request.** List the repository's open pull requests, read each
  one's diff once, and search the diff for each record's slug. A hit means a
  session's work on that record is waiting on review, such as a plan that adds a
  task citing a problem, or a finalize that moves a brief. On either route, read
  them with `gh` wherever `gh auth status` exits 0:

  ```bash
  gh pr list --repo <primaryRepository> --state open --limit 100 --json number,title,headRefName
  gh pr diff <number> --repo <primaryRepository>
  ```

  A list of 100 is a bound hit, said as such. Where `gh` is absent or not logged
  in, the GitHub MCP server's pull request tools are the alternative; with neither,
  this half is unavailable, and the plan names `gh auth login` as the fix. In a cloud
  session `gh auth status` has exited 1 on an invalid `GH_TOKEN`, so the cloud route
  normally takes the GitHub MCP server.

Either listing failing is reported as **unavailable**, and the plan says which
records it could not clear. It is never read as "nothing in flight".

## 4. Print the plan

Print one table before anything is launched, with the columns the skill names.
Every record in the bucket gets a row, including the skipped ones, whose action
names what caught them. Then name the launch parameters once:

- the snapshot's commit and any difference step 1 found;
- the launch route from step 2;
- the environment name and ID, and the repository URL;
- the model and permission mode the sessions get, and where each comes from:
  inherited from this session on the cloud route, or on the CLI route the ones the
  owner named, else this session's model and `auto`;
- how many sessions are about to be created.

`dry-run` stops here, and a render-only run stops after printing the prompts.
Otherwise continue without asking: the invocation was the authorization, and the
plan is what it authorized.

## 5. Launch one session per record

The prompt below is the same on both routes, apart from one paragraph the CLI route
adds; only the launch that carries it differs. A launch that errors is reported
beside its record with the error text. Retry it once only when the error reads as
transient, such as a network or rate-limit message, with the same arguments; a
second failure stands.

### On the cloud route

For each record marked for dispatch, call `create_session` with:

| Parameter | Value |
|---|---|
| `environment_id` | the declared environment ID |
| `source_url` | the declared repository URL |
| `title` | the skill's title for the record |
| `tags` | the record's tag, and `dispatched-by:<this session's ID>` |
| `prompt` | the frame below, with the skill's stage block in its place |
| `permission_mode` | omitted, so the session inherits this one's. Never `plan`: it blocks the session on an approval nobody is watching for, and every stage skill already stops for the owner |
| `model` | omitted unless the owner named one. Each stage skill asks for the strongest model available and says so itself when it has less; the report names what the sessions got |

The calls are independent of one another, so issue them together where the harness
allows.

### On the CLI route

`claude --cloud "<prompt>"` creates a session only from a terminal, and `script`
supplies one. It prints the session's title, link, and ID, then exits without
attaching. Write a launcher and the settings file once, in scratch, so that neither
the prompt nor the title passes through shell quoting:

```bash
cat > "$scratch/launch.sh" <<'EOF'
#!/bin/bash
# $1 prompt file, $2 title file, $3 settings file, $4 model, $5 permission mode
exec claude --cloud "$(cat "$1")" -n "$(cat "$2")" --model "$4" --permission-mode "$5" --settings "$3"
EOF
printf '{"remote":{"defaultEnvironmentId":"%s"}}\n' "<the declared environment ID>" \
  > "$scratch/dispatch-settings.json"
```

Then, for each record, write its prompt to `$scratch/<slug>.prompt` and its title to
`$scratch/<slug>.title`, and launch from the repository root, one record after
another:

```bash
script -qec "bash $scratch/launch.sh $scratch/<slug>.prompt $scratch/<slug>.title $scratch/dispatch-settings.json <model> <permission mode>" \
  /dev/null </dev/null > "$scratch/<slug>.launch" 2>&1
echo "EXIT=$?"
tr -d '\r' < "$scratch/<slug>.launch" | grep -aoE '(Created cloud session: [^[:cntrl:]]*|View: https://claude\.ai/code/[A-Za-z0-9_]+|Resume with: claude --teleport [A-Za-z0-9_]+|Branch [^[:cntrl:]]*|Error: [^[:cntrl:]]*)'
```

A launch counts only with exit 0 and a `Created cloud session:` line naming the
title. The session ID is the `session_…` on the `Resume with` line. A `Branch … is
ahead` line confirms that the session starts without this checkout's unpushed
commits, which step 1 already assumes.

### The prompt

The prompt is the only context a session starts with. Fill every angle bracket,
replace the stage block with the skill's own, drop the sibling paragraph when the
skill found no siblings, and drop the route paragraph on the cloud route:

```text
You are a Claude Code on the web session on <primaryRepository>, started by the
<dispatch skill> skill from session <this session's ID> for one <record kind>.
Start your first reply with the line `<title>` so the session is identifiable
from the session list.

<route paragraph>

Turn-one check first, from docs/work/claude-code-web.md: run `git submodule
status`. A leading `-` on `workshop` means no shared skill is invocable this
session; say so, run `bash scripts/agent/session-start.sh`, and read
`.agents/skills/<stage skill>/SKILL.md` from disk instead of invoking it. Read
the SessionStart hook's output for where the checkout stands relative to
origin/main before trusting task or problem documents.

<stage block>

<sibling paragraph>

Follow AGENTS.md throughout, including every rule it sets on what a session may
read, run, or operate. <stage skill> commits and never pushes. When the owner asks to
land the result, use the ship skill: this repository's cloud ship policy
applies, and main is never a push target.
```

On the CLI route, the route paragraph is:

```text
A local session started this session with `claude --cloud`, which cannot read
it back. So right after the title line, call the claude-code-remote
`get_session` with no argument and give one line from its answer:
`Session: <environment_id>, <permission mode>`.
```

## 6. Verify the sessions exist

A launch's output is a claim; the session record is the evidence.

On the cloud route, for each returned ID, call `get_session` and check that it
answers with that ID, the declared environment, the title and tags you set, a
`parent_session_id` equal to this session's ID where the record carries one, and a
`status_bucket` of working, blocked, or review ready. A session that reads failed, or
is missing, is reported as such, with `list_events` on it, filtered to result and
system events, for the reason. The link to a session is
`https://claude.ai/code/<session ID>`.

On the CLI route, read each session's events with `get_run_log` and its session ID.
That action belongs to the `RemoteTrigger` tool, the one behind `/schedule`; it reads
any session by ID and creates nothing. Load its schema first where it is deferred.
Once the session's first turn has run, about half a minute after launch, the log
must show:

- the prompt;
- an `init` line naming the model you passed. The line names the model and the
  working directory only;
- a first reply that starts with the title, then the `Session:` line naming the
  declared environment ID and the permission mode you passed.

A log that ends in an error, or a `Session:` line naming another environment, is
reported with the log's last events. Without `RemoteTrigger`, this check is
unavailable: say so, and give the links for the owner to open. The link to a
session is the `View` line's URL, `https://claude.ai/code/<session ID>`.

## 7. Report

Lead with the sessions, because opening them is what the owner does next:

| Record | Session | Status |
|---|---|---|
| `<slug>` | the title, linked to `https://claude.ai/code/<session ID>` | from step 6 |

Then, briefly:

- **Skipped**, one line per record: what caught it, and the argument that sends it
  anyway where the skill has one.
- **Where they run**: the launch route, snapshot commit, environment name and ID,
  repository URL, model, and permission mode, and on the cloud route whether this
  session's environment matched the declaration.
- **Checks that could not run**: an unavailable in-flight listing, a bound hit, or a
  difference between this checkout and the default branch.
- **What happens next**: what each session stops at, and that the owner continues
  each one at its link and lands the result from there with `ship`.
  - On the cloud route, a session whose turn fails reports back here as a
    child-session event where the harness supports it; nothing else wakes this
    session. Checking on one later is `get_session` by its ID. Stopping one is
    `archive_session` on the owner's word, never on a dispatch skill's.
  - On the CLI route, no session reports back to this one, not even a failed turn.
    Checking on one later is its link at claude.ai/code, where it sits in the
    ordinary session list, or `get_run_log` on its session ID. The owner can add a
    message to one with `claude -p "<message>" --cloud <session ID>`. Archiving
    one is the owner's, at claude.ai/code.
- **Nothing written here**: the working tree is unchanged, and nothing was committed
  or pushed. The snapshot directory, and on the CLI
  route the launcher, settings, prompt, and launch-output files, are scratch.
- For a dry or render-only run, say which, and what stopped the launch.

## Routes tried and set aside

These were tried from a local session on Claude Code 2.1.311 on 2026-10-27:

- **Scheduled tasks**, through the `RemoteTrigger` tool behind `/schedule`. They
  launch sessions with tags, but those sessions sit under "Scheduled" at
  claude.ai/code with no archive option, and a cloud dispatcher's `list_sessions`
  does not show them. So dispatch does not create scheduled tasks; it uses the tool
  only to read a session's log.
- Any `--print` form of `--cloud`, which is refused as interactive only.
  `claude -p "<message>" --cloud <session ID>` only messages an existing session.
- `--cloud` without a terminal, which is refused as needing one.
- `--environment` with the declared `env_` ID, which accepts self-hosted `ccpool_`
  IDs only.
- An Agent tool subagent with remote isolation, which ran in a local worktree.

## See also

- [`problem-plan-cloud`](SKILL.md), [`task-finalize-cloud`](../task-finalize-cloud/SKILL.md),
  and [`task-implement-cloud`](../task-implement-cloud/SKILL.md) — the skills that
  use this procedure
- [`claude-web-session`](../claude-web-session/SKILL.md) — the declaration inspect
  procedure step 2 follows
- `docs/work/claude-code-web.md` in the consuming repository — the environment, what
  a cloud session can do, and the turn-one check; its shape is the
  [Claude Code Web declarations](../../../docs/claude-code-web.md) standard
- `docs/work/ship/cloud.md` in the consuming repository, read by the
  [`ship`](../ship/SKILL.md) skill — how each session lands its result
