#!/bin/zsh
# Records the scripted work-session flow of the demo app as a GIF for the README.
# usage: scripts/demo/record-demo-flow.sh <ko|en> [seconds] [output.gif]
# Needs a debug app bundle with the current code: USAGEBAR_OUTPUT_DIR=<dir> zsh scripts/build-app.sh debug
# and screen-recording permission for the terminal. Frames are window-only captures, so no background leaks in.
set -euo pipefail
root="${0:A:h:h:h}"; lang="${1:-ko}"; secs="${2:-9.5}"; out="${3:-$root/docs/images/flow-$lang.gif}"
app="${USAGEBAR_OUTPUT_DIR:-$root/build}/UsageBar.app/Contents/MacOS/UsageBar"
[[ -x "$app" ]] || { print -u2 "Build a debug app first: USAGEBAR_OUTPUT_DIR=... zsh scripts/build-app.sh debug"; exit 1; }
tools="$(mktemp -d)"; trap 'rm -rf -- "$tools"' EXIT
swiftc -O -o "$tools/winid" "$root/scripts/demo/winid.swift"
swiftc -O -o "$tools/png2gif" "$root/scripts/demo/png2gif.swift"
mkdir -p "$tools/frames"
"$app" --demo --ui-window --ui-demo-flow -AppleLanguages "($lang)" >/dev/null 2>&1 & pid=$!
wid=""; for i in {1..30}; do sleep 0.2; wid="$("$tools/winid" "$pid")"; [[ -n "$wid" ]] && break; done
[[ -n "$wid" ]] || { kill $pid; print -u2 "No window found"; exit 1; }
start=$(date +%s.%N); n=0
while (( $(echo "$(date +%s.%N) - $start < $secs" | bc) )); do
  screencapture -x -o -l "$wid" "$(printf '%s/f%03d.png' "$tools/frames" $n)"; n=$((n+1))
done
elapsed=$(echo "$(date +%s.%N) - $start" | bc)
kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
"$tools/png2gif" "$out" "$(echo "scale=2; $n / $elapsed" | bc)" 540 "$tools"/frames/f*.png
print -- "Wrote $out"
