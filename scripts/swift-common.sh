#!/bin/bash
# Shared SwiftPM flags for build/test. Caches live under /tmp so restricted shells and CI do not
# write into the user's ~/Library caches.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/e900-clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/e900-swift-cache}"
build_dir="${E900_BUILD_DIR:-/tmp/e900-control-build}"
swift_flags=(--package-path "$repo_root/app" --scratch-path "$build_dir" --cache-path /tmp/e900-spm-cache
    --config-path /tmp/e900-spm-config --security-path /tmp/e900-spm-security --disable-sandbox)
# Swift 6.4's default swiftbuild backend hit `dsymutil: Operation not permitted` in a restricted
# shell; the native backend works there. Older toolchains have no --build-system flag at all.
if swift build --help 2>/dev/null | grep -q -- '--build-system'; then
    swift_flags+=(--build-system "${E900_BUILD_SYSTEM:-native}")
fi
