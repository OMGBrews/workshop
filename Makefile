.PHONY: check test links json lint

# The one public, standalone verification suite. Keep this list explicit:
# The retired task-queue entry point is checked alongside the other public scripts.
check: test links json lint

test:
	bash tests/run-tests.sh
	bash Tools/check-agent-surfaces.sh .
	bash Tools/check-definition-of-done.sh . --conformant

links:
	bash Tools/check-markdown-links.sh .

json:
	find . -path ./.git -prune -o -name '*.json' -type f -print0 | xargs -0 -r -n1 python3 -m json.tool > /dev/null

lint:
	shellcheck docs/templates/cloud-sessions/harness-signals.sh docs/templates/cloud-sessions/agent-session-start.sh docs/templates/cloud-sessions/session-start.sh Tools/check-agent-surfaces.sh Tools/cloud-git-lfs.sh Tools/check-command-signal-hygiene.sh Tools/check-definition-of-done.sh Tools/check-docs-work-conformance.sh Tools/check-markdown-links.sh Tools/check-skill-roster-freshness.sh Tools/docs-only-diff.sh Tools/migrate-kaizen-journal.sh Tools/migrate-task-format.sh Tools/normalize-remote.sh Tools/rewrite-moved-markdown-links.sh Tools/sync-skill-symlinks.sh Tools/sync-rules-symlinks.sh Tools/hooks/post-checkout Tools/hooks/post-merge Tools/hooks/post-rewrite Tools/devcontainer/build/lib.sh Tools/devcontainer/build/finalize-claude.sh Tools/devcontainer/build/setup.sh Tools/devcontainer/build/harness-claude.sh Tools/devcontainer/build/harness-codex.sh Tools/devcontainer/build/harness-omp.sh Tools/devcontainer/connect.sh Tools/devcontainer/install-packages.sh Tools/devcontainer/post_install.sh Tools/devcontainer/update-harnesses.sh Tools/devcontainer/validate_setup.sh .agents/skills/task-finalize/task-history-baseline.sh .agents/skills/task-queue/run.sh tests/*.sh
