#!/bin/bash
# Build and install once (to /Applications, or ~/Applications), then open the installed app.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")" && pwd)"
app="/Applications/E900 Control.app"
[[ -d $app ]] || app="$HOME/Applications/E900 Control.app"
if [[ ! -x "$app/Contents/MacOS/E900Control" ]]; then
    bash "$repo_root/scripts/install-and-accept.sh" --skip-tests --no-accept
    app="/Applications/E900 Control.app"; [[ -d $app ]] || app="$HOME/Applications/E900 Control.app"
fi
open "$app"
