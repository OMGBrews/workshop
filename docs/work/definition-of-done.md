# Definition of done

The required evidence for Workshop applies to every change. The suite runs from
a standalone clone and does not require a private upstream, hq, or another
fleet repository.

| Required evidence | Command | Pass condition | Applies to |
|---|---|---|---|
| Public verification suite | `make check` | Exit 0 after public regression tests, agent-surface conformance, Markdown links, JSON validation, and the shellcheck allow-list. | Every change |

The workflow runs this suite on every push, pull request, and tag. An active
GitHub ruleset on `main`, with no bypass actors, requires the three matrix
statuses `check (Python 3.11)`, `check (Python 3.12)`, and
`check (Python 3.13)`. Workshop changes land through pull requests. Maintainer
authorization and review remain separate from those status results.
