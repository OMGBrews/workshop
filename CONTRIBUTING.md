# Contributing to Workshop

Workshop is the hand-authored source of truth. Contributions are welcome
through the normal pull-request workflow.

Create a branch, make a focused change, and run `make check` in a standalone
clone before opening a pull request. Keep documentation links relative, retain
the standing rules imported by [CLAUDE.md](CLAUDE.md), and describe any user-
visible change in [CHANGELOG.md](CHANGELOG.md).

Use [the shared verification terminology](docs/verification-terminology.md)
when changing checks, CI, definitions of done, release, or deployment guidance.

Workshop's landing gate includes the three platform-required statuses reported
as `check (Python 3.11)`, `check (Python 3.12)`, and `check (Python 3.13)` by the
`Workshop checks` workflow.

## Security reports

Do not open a public issue for a vulnerability. Follow
[SECURITY.md](SECURITY.md) instead.
