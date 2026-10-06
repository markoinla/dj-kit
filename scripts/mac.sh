#!/usr/bin/env bash
# Sync this repo to mac-ci and run a command there.
#   scripts/mac.sh <run-name> '<command>'     e.g. scripts/mac.sh stems 'cd Packages/StemsKit && swift build'
#   scripts/mac.sh <run-name> --down          delete the remote run dir
# Remote dir: agent@mac-ci:~/runs/djt-<run-name>/ (house rules: ~agent/README.md on the Mac).
# Each parallel worker uses its own run-name so builds don't collide.
set -euo pipefail
name="${1:?run name}"; shift
host="agent@mac-ci"
dir="runs/djt-${name}"
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "--down" ]]; then
  ssh -o BatchMode=yes "$host" "rm -rf ~/$dir"
  exit 0
fi
ssh -o BatchMode=yes "$host" "mkdir -p ~/$dir"
rsync -az --delete \
  --exclude .git --exclude .dd --exclude .build --exclude .venv --exclude '*.xcodeproj' \
  --exclude .cache --exclude .uv --exclude 'out/' --exclude .swiftpm \
  "$root/" "$host:$dir/"
cmd="${*:-true}"
ssh -o BatchMode=yes "$host" "bash -lc $(printf '%q' "cd ~/$dir && $cmd")"
