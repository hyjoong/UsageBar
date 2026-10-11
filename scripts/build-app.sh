#!/bin/zsh
set -euo pipefail

usagebar_root="${0:A:h:h}"
usagebar_mode="${1:-release}"
if [[ "$usagebar_mode" == "--help" || "$usagebar_mode" == "-h" ]]; then
  cat <<'HELP'
Usage: scripts/build-app.sh [release|debug]

Builds UsageBar.app, embeds Sparkle with symlinks preserved, and verifies signing.
Default: local ad-hoc app in build/UsageBar.app, with updates unconfigured unless
SUFeedURL and SUPublicEDKey are present in Info.plist or supplied below.

Environment:
  USAGEBAR_BUILD_ROOT            SwiftPM scratch directory (default: .build)
  USAGEBAR_OUTPUT_DIR            App output directory (default: build)
  USAGEBAR_SPARKLE_ROOT          Optional Sparkle artifact root with Sparkle.xcframework
  USAGEBAR_FEED_URL              HTTPS appcast URL
  USAGEBAR_PUBLIC_ED_KEY         Sparkle public Ed25519 key (base64, 32 bytes)
  USAGEBAR_SIGNING_IDENTITY      Exact Developer ID Application name or SHA-1;
                                omitted or '-' means local ad-hoc signing

Developer ID builds sign Sparkle inside-out with hardened runtime and timestamps.
Both feed and public key may be absent for a signed development artifact;
prepare-release.sh requires them before distribution preparation.
No notarization, key generation, account changes, or public uploads occur here.

Isolated update fixtures (debug + ad-hoc only):
  USAGEBAR_UPDATE_TEST=1         Sets dev.hyjoong.usagebar.updatetest + test marker
  USAGEBAR_ALLOW_LOOPBACK_FEED=1 Allows HTTP localhost/127.0.0.1/::1 in that fixture
  USAGEBAR_FIXTURE_BUILD_VERSION Overrides CFBundleVersion only in that fixture
  USAGEBAR_FIXTURE_SHORT_VERSION Overrides short version only in that fixture
Use a separate USAGEBAR_OUTPUT_DIR for fixtures. Ordinary builds retain versions
from Resources/Info.plist. Python 3 and Xcode command-line tools are required.
HELP
  exit 0
fi
[[ "$#" -le 1 && ( "$usagebar_mode" == "release" || "$usagebar_mode" == "debug" ) ]] || {
  print -u2 "Expected release or debug. Use --help for options."; exit 1
}

usagebar_python="$(command -v python3)"
usagebar_support="$usagebar_root/scripts/release-support.py"
usagebar_scratch="${USAGEBAR_BUILD_ROOT:-$usagebar_root/.build}"
usagebar_output="${USAGEBAR_OUTPUT_DIR:-$usagebar_root/build}"
usagebar_scratch="${usagebar_scratch:A}"
usagebar_output="${usagebar_output:A}"
usagebar_identity="${USAGEBAR_SIGNING_IDENTITY:--}"
usagebar_developer=0
if [[ "$usagebar_identity" != "-" ]]; then
  usagebar_identity="$("$usagebar_python" "$usagebar_support" signing-identity "$usagebar_identity")"
  usagebar_developer=1
fi

mkdir -p "$usagebar_output"
usagebar_stage="$(mktemp -d "$usagebar_output/.usagebar-build.XXXXXX")"
trap 'rm -rf -- "$usagebar_stage"' EXIT
usagebar_bundle="$usagebar_stage/UsageBar.app"
mkdir -p "$usagebar_bundle/Contents/MacOS" "$usagebar_bundle/Contents/Resources" "$usagebar_bundle/Contents/Frameworks"
cp "$usagebar_root/Resources/Info.plist" "$usagebar_bundle/Contents/Info.plist"
"$usagebar_python" "$usagebar_support" configure "$usagebar_bundle/Contents/Info.plist" "$usagebar_mode" "$usagebar_developer"

cd "$usagebar_root"
swift build -c "$usagebar_mode" --product UsageBar --scratch-path "$usagebar_scratch"
usagebar_bin="$(swift build -c "$usagebar_mode" --scratch-path "$usagebar_scratch" --show-bin-path)"
cp "$usagebar_bin/UsageBar" "$usagebar_bundle/Contents/MacOS/UsageBar"
cp "$usagebar_root/Resources/setup-claude.command" "$usagebar_bundle/Contents/Resources/setup-claude.command"
# Korean is the source language (keys), English is compiled from the string catalog.
mkdir -p "$usagebar_bundle/Contents/Resources/ko.lproj"
xcrun xcstringstool compile "$usagebar_root/Resources/Localizable.xcstrings" \
  --output-directory "$usagebar_bundle/Contents/Resources" >/dev/null
chmod +x "$usagebar_bundle/Contents/MacOS/UsageBar" "$usagebar_bundle/Contents/Resources/setup-claude.command"
if [[ -f "$usagebar_root/Resources/AppIcon.icns" ]]; then
  cp "$usagebar_root/Resources/AppIcon.icns" "$usagebar_bundle/Contents/Resources/AppIcon.icns"
fi
usagebar_framework_source="$("$usagebar_python" "$usagebar_support" framework "${USAGEBAR_SPARKLE_ROOT:-$usagebar_scratch/artifacts}")"
usagebar_framework="$usagebar_bundle/Contents/Frameworks/Sparkle.framework"
/usr/bin/ditto "$usagebar_framework_source" "$usagebar_framework"
cp "${usagebar_framework_source:h:h:h}/LICENSE" "$usagebar_bundle/Contents/Resources/Sparkle-LICENSE.txt"
"$usagebar_python" "$usagebar_support" bundle-layout "$usagebar_bundle"

typeset -a usagebar_sign_flags
usagebar_sign_flags=(--force --sign "$usagebar_identity")
if [[ "$usagebar_developer" == 1 ]]; then
  usagebar_sign_flags+=(--options runtime --timestamp)
else
  usagebar_sign_flags+=(--options 0 --timestamp=none)
fi
# Sparkle's documented inside-out order. Do not use --deep when signing.
usagebar_sparkle_version="$usagebar_framework/Versions/Current"
/usr/bin/codesign "${usagebar_sign_flags[@]}" "$usagebar_sparkle_version/XPCServices/Installer.xpc"
/usr/bin/codesign "${usagebar_sign_flags[@]}" --preserve-metadata=entitlements "$usagebar_sparkle_version/XPCServices/Downloader.xpc"
/usr/bin/codesign "${usagebar_sign_flags[@]}" "$usagebar_sparkle_version/Autoupdate"
/usr/bin/codesign "${usagebar_sign_flags[@]}" "$usagebar_sparkle_version/Updater.app"
/usr/bin/codesign "${usagebar_sign_flags[@]}" "$usagebar_framework"
/usr/bin/codesign "${usagebar_sign_flags[@]}" "$usagebar_bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$usagebar_bundle"
if [[ "$usagebar_developer" == 1 ]]; then
  "$usagebar_python" "$usagebar_support" verify-developer "$usagebar_bundle"
fi

# Replace only after the complete temporary bundle verifies; preserve the last build on failure.
usagebar_destination="$usagebar_output/UsageBar.app"
if [[ -e "$usagebar_destination" || -L "$usagebar_destination" ]]; then
  [[ -d "$usagebar_destination" && ! -L "$usagebar_destination" ]] || {
    print -u2 "Refusing to replace a non-directory or symlink at $usagebar_destination"; exit 1
  }
  mv "$usagebar_destination" "$usagebar_stage/previous.app"
fi
if ! mv "$usagebar_bundle" "$usagebar_destination"; then
  [[ ! -d "$usagebar_stage/previous.app" ]] || mv "$usagebar_stage/previous.app" "$usagebar_destination"
  exit 1
fi
printf '%s\n' "$usagebar_destination"
