# Signal-hygiene reference

The exact mechanics, idioms, and incidents behind [`signal-hygiene.md`](signal-hygiene.md). That file is the always-loaded rule; read this one when writing a check or script, or when investigating how a green signal lied.

## Preserving a verdict

- Scripts run under `set -euo pipefail`. Do not silence a fallible command with `-q`; `2>/dev/null` is fine only when the failure is *handled* (a deliberate fallback), never to hide it.
- Foreground, `<cmd> > out.txt 2>&1; echo "EXIT=$?"` is enough. Backgrounded it is not: the harness reports the whole pipeline's status and swallows the trailing echo, so a red run announces `exit code 0`. Write the verdict *into* the artifact — `{ cmd; echo "EXIT=$?"; } > out.txt 2>&1` — then read the file. The braces are load-bearing: without them the redirect binds to `cmd` alone and the verdict lands where nobody looks (2026-07-22).
- Piping a fallible command into `tail`/`head` reports the *pipe's* status, so a red run announces itself as success. The sanctioned shape redirects first, then reads: a trailing `tail` over the log file is fine, because there the verdict was already captured. `Tools/check-command-signal-hygiene.sh` screens for the bad shapes mechanically; quoting one deliberately takes a `signal-hygiene: counter-example` marker.

## Why "nothing found" can lie

- A harness's shell working directory can persist between calls, so a bare `cd` in one command silently rebases every relative path in the ones after it. Use absolute paths, or confine the change to a subshell — `(cd dir && ...)`. An empty directory and a wrong directory print the same nothing.
- Many recursive search tools honour ignore files by default — ripgrep, ugrep, some harness-bundled `grep` shims — so a search silently skips whatever `.gitignore` excludes, sibling clones and vendored trees included. A negative result ("no other caller", "no third instance") is evidence only once the tool is confirmed to have seen the excluded directories; pass the paths explicitly.
- Git exits 0 and prints nothing for a `git log`/`git diff` pathspec that is untracked, gitignored, or in another repository — byte-identical to "nothing changed here". `git ls-files --error-unmatch -- <path>` settles it; its answer is "tracked *now*", so a path deleted since the base commit fails it too. Either way the verdict is *unknown*, not *clean*.

## Push verification

`git push` is loud in both directions; reaching for a secondary check is usually the tell that you discarded the primary one. SHA equality is not that check: a dropped rebase commit makes `HEAD` match `origin/main` precisely because the work vanished — a real incident (2026-07-14), not a hypothetical. Where you genuinely need to prove a remote contains a commit — for instance, before recording a submodule pointer that must not dangle for anyone who clones — the question is **containment, after a fetch**:

```bash
git -C "$repo" fetch origin
git -C "$repo" merge-base --is-ancestor "$sha" origin/main   # exit 0 = the remote contains it
```

## See also

- [`kaizen-guide.md`](kaizen-guide.md) — the practice these rules graduated out of, and the graduation contract that stops a lesson losing its content in transit. The escalation trigger they once carried fired in 2026-08 and was replaced by mechanism.
