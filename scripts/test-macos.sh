#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/e900-clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/e900-swift-cache}"
swift test --package-path "$repo_root/app" --scratch-path /tmp/e900-control-build --cache-path /tmp/e900-spm-cache --config-path /tmp/e900-spm-config --security-path /tmp/e900-spm-security --disable-sandbox --build-system native
