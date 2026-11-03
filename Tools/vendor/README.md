# Vendored Markdown parser

This directory distributes Mistune 3.1.3 for offline Markdown anchor parsing.
Consumers need Python 3.11 or newer and no package installation. Workshop tests
run on Python 3.11–3.13. This avoids Mistune’s conditional
`typing-extensions` dependency on older Python versions.

The unmodified `mistune/` package and its BSD-3-Clause `LICENSE` come from the
PyPI wheel `mistune-3.1.3-py3-none-any.whl`, SHA-256
`1a32314113cff28aa6432e99e522677c8587fd83e3d51c29b82a52409c842bd9`.
To update, download an explicitly pinned wheel with `pip download --no-deps`,
verify its digest, replace the package and license, and run `make check`.

`../markdown-anchors.py` handles GitHub-style slug allocation and explicit
anchors; Mistune handles block and inline parsing. The extractor retains its
existing supported destination grammar.
