#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -x "$repo_root/dist/E900 Control.app/Contents/MacOS/E900Control" ]]; then
    bash "$repo_root/scripts/build-macos.sh"
fi
open "$repo_root/dist/E900 Control.app"
