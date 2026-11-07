#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${E900_BUILD_DIR:-/tmp/e900-control-build}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/e900-clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/e900-swift-cache}"
swift build --package-path "$repo_root/app" --scratch-path "$build_dir" --cache-path /tmp/e900-spm-cache --config-path /tmp/e900-spm-config --security-path /tmp/e900-spm-security --disable-sandbox --build-system native -c release
app_dir="$repo_root/dist/E900 Control.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/release/E900Control" "$app_dir/Contents/MacOS/E900Control"
cp "$repo_root/app/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"
printf 'Built: %s\n' "$app_dir"
