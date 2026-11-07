#!/bin/bash
# One-shot: unit tests → release build → install the .app → headless hardware acceptance.
#   bash scripts/install-and-accept.sh                 # full run (headset powered on)
#   bash scripts/install-and-accept.sh --no-accept     # only test, build and install
#   bash scripts/install-and-accept.sh --skip-tests --video-seconds 8 --candidates
# Remaining options go to `E900Control --accept` (see --help). Exit code 1 = a gate failed.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
run_tests=1; run_accept=1; accept_args=()
for arg in "$@"; do
    case "$arg" in
        --skip-tests) run_tests=0 ;;
        --no-accept) run_accept=0 ;;
        *) accept_args+=("$arg") ;;
    esac
done

if [[ $run_tests == 1 ]]; then bash "$repo_root/scripts/test-macos.sh"; fi
bash "$repo_root/scripts/build-macos.sh"

dest="/Applications"
[[ -w "$dest" ]] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
app="$dest/E900 Control.app"
pkill -x E900Control 2>/dev/null || true
rm -rf "$app"
ditto "$repo_root/dist/E900 Control.app" "$app"
printf 'Installed: %s\n' "$app"

if [[ $run_accept == 1 ]]; then
    cd "$repo_root"
    "$app/Contents/MacOS/E900Control" --accept ${accept_args[@]+"${accept_args[@]}"}
fi
