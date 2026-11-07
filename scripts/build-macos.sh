#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-common.sh"
swift build "${swift_flags[@]}" -c release
bin_dir="$(swift build "${swift_flags[@]}" -c release --show-bin-path)"
app_dir="$repo_root/dist/E900 Control.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/E900Control" "$app_dir/Contents/MacOS/E900Control"
cp "$repo_root/app/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"
printf 'Built: %s\n' "$app_dir"
