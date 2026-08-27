.PHONY: check test links json lint

# The one public, standalone verification suite. Keep this list explicit:
# task-queue runner scripts have known shellcheck findings and stay named exclusions until those
# findings are repaired rather than disappearing behind recursive linting.
check: test links json lint

test:
	bash tests/run-tests.sh
	bash Tools/check-agent-surfaces.sh .

links:
	bash Tools/check-markdown-links.sh .

json:
	find . -path ./.git -prune -o -name '*.json' -type f -print0 | xargs -0 -r -n1 python3 -m json.tool > /dev/null

lint:
	shellcheck Tools/check-agent-surfaces.sh Tools/check-docs-work-conformance.sh Tools/check-markdown-links.sh Tools/check-skill-roster-freshness.sh Tools/docs-only-diff.sh Tools/migrate-kaizen-journal.sh Tools/normalize-remote.sh Tools/rewrite-moved-markdown-links.sh Tools/sync-skill-symlinks.sh Tools/hooks/post-checkout Tools/hooks/post-merge Tools/hooks/post-rewrite Tools/devcontainer/build/lib.sh Tools/devcontainer/build/setup.sh Tools/devcontainer/build/harness-claude.sh Tools/devcontainer/build/harness-codex.sh Tools/devcontainer/build/harness-omp.sh Tools/devcontainer/install-packages.sh Tools/devcontainer/post_install.sh Tools/devcontainer/update-harnesses.sh Tools/devcontainer/validate_setup.sh tests/*.sh
