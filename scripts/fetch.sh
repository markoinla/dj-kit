#!/usr/bin/env bash
# Copy a file or folder back from a mac-ci run dir:  scripts/fetch.sh <run-name> <remote-path> <local-path>
set -euo pipefail
rsync -az "agent@mac-ci:runs/djt-$1/$2" "$3"
