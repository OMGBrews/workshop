#!/bin/bash
# Standard apt packages for a devcontainer image.
# Runs as root during the Docker build, before the USER switch.
#
# Usage in a Dockerfile:
#   COPY workshop/Tools/devcontainer/install-packages.sh /tmp/install-packages.sh
#   RUN bash /tmp/install-packages.sh
#
# The set is deliberately project-neutral: the tools the Workshop build helpers,
# hooks, and documentation workflows assume, and nothing else. Anything tied to
# one base image (clearing an expired apt source) or to one project (a game
# engine, a recording toolchain) belongs in that repository's own layer, which
# is free to run before or after this one.

set -euo pipefail

apt-get update && apt-get install -y \
    curl \
    jq \
    libfontconfig1 \
    libfreetype6 \
    ripgrep \
    shellcheck \
    tmux \
    unzip \
    wget \
    && rm -rf /var/lib/apt/lists/*
