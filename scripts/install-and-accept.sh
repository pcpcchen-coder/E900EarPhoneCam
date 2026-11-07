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
# Register the fresh copy right away; otherwise `open` can fail with -10810 for a few seconds.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" 2>/dev/null || true
printf 'Installed: %s\n' "$app"

if [[ $run_accept == 1 ]]; then
    # Launch through LaunchServices, not by exec'ing the binary: when a shell (Terminal, Claude)
    # starts it directly, macOS charges Bluetooth access to that parent process and TCC kills the
    # app with SIGABRT because the parent has no NSBluetoothAlwaysUsageDescription.
    # The app (its own TCC identity) may not write into ~/Documents etc., so it writes to a
    # staging folder it can always use; the results are copied into the repo afterwards.
    reports="$repo_root/acceptance-reports"; mkdir -p "$reports"
    staging="$HOME/Library/Caches/com.pcpcchen.e900control/acceptance"; mkdir -p "$staging"
    stamp="$(date +%Y%m%d-%H%M%S)"
    log="$staging/E900-$stamp.log"; : > "$log"
    report="$staging/E900-$stamp.md"
    for a in ${accept_args[@]+"${accept_args[@]}"}; do
        [[ $a == --report || $a == --help ]] && { report=""; break; }
    done
    extra=(); [[ -n $report ]] && extra=(--report "$report")
    tail -n +1 -f "$log" & tailer=$!
    launched=0
    for attempt in 1 2 3 4 5; do
        if open -W -n --stdout "$log" --stderr "$log" "$app" --args --accept ${extra[@]+"${extra[@]}"} ${accept_args[@]+"${accept_args[@]}"}; then
            launched=1; break
        fi
        sleep 2   # LaunchServices not ready yet (-10810); retry
    done
    sleep 0.3; kill "$tailer" 2>/dev/null || true; wait "$tailer" 2>/dev/null || true
    [[ $launched == 1 ]] || { echo "無法以 open 啟動 $app" >&2; exit 1; }
    cp "$staging/E900-$stamp".* "$reports/" 2>/dev/null || true
    [[ -n $report && -f $report ]] && printf '報告已複製：%s\n' "$reports/$(basename "$report")"
    report="${report:+$reports/$(basename "$report")}"; log="$reports/$(basename "$log")"
    # `open -W` does not forward the app's exit status; decide from the output instead.
    if grep -qE "藍牙不可用|crashed|TCC" "$log"; then exit 1; fi
    if [[ -n $report && -f $report ]] && grep -q "有項目失敗" "$report"; then exit 1; fi
fi
