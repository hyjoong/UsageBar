#!/bin/zsh
set -euo pipefail
usagebar_root="${0:A:h:h}"
usagebar_mode="${1:-release}"
usagebar_scratch="${USAGEBAR_BUILD_ROOT:-$usagebar_root/.build}"
cd "$usagebar_root"
swift build -c "$usagebar_mode" --scratch-path "$usagebar_scratch"
usagebar_bin="$(swift build -c "$usagebar_mode" --scratch-path "$usagebar_scratch" --show-bin-path)"
usagebar_bundle="$usagebar_root/build/UsageBar.app"
mkdir -p "$usagebar_bundle/Contents/MacOS" "$usagebar_bundle/Contents/Resources"
cp "$usagebar_bin/UsageBar" "$usagebar_bundle/Contents/MacOS/UsageBar"
cp "$usagebar_root/Resources/Info.plist" "$usagebar_bundle/Contents/Info.plist"
cp "$usagebar_root/Resources/setup-claude.command" "$usagebar_bundle/Contents/Resources/setup-claude.command"
chmod +x "$usagebar_bundle/Contents/Resources/setup-claude.command"
if [[ -f "$usagebar_root/Resources/AppIcon.icns" ]]; then
  cp "$usagebar_root/Resources/AppIcon.icns" "$usagebar_bundle/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$usagebar_bundle"
printf '%s\n' "$usagebar_bundle"
