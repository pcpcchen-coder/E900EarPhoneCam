#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-common.sh"
swift test "${swift_flags[@]}"
