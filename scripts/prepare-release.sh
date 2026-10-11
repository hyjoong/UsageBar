#!/bin/zsh
set -euo pipefail

usagebar_root="${0:A:h:h}"
usagebar_app="$usagebar_root/build/UsageBar.app"
usagebar_profile=""
usagebar_output=""
usagebar_generate=0
usagebar_account=""
usagebar_tools=""
usagebar_download_prefix=""
usagebar_notes=""

usagebar_help() {
  cat <<'HELP'
Usage: scripts/prepare-release.sh --keychain-profile PROFILE [options]

Verify a Developer ID release, submit a temporary ZIP to Apple's notarization
service, staple and validate the copied app, then create a distribution ZIP.
The original app is not modified. Nothing is uploaded to public hosting.
Requires existing notarytool keychain credentials; no password arguments,
credential registration, key generation, or app signing is performed here.

Options:
  --app PATH                    Signed app (default: build/UsageBar.app)
  --keychain-profile NAME       Existing notarytool credential profile (required)
  --output-dir PATH             Output (default: build/releases/VERSION-BUILD)
  --generate-appcast            Also generate and verify a signed appcast
  --eddsa-account NAME          Existing named Sparkle keychain account
  --sparkle-tools PATH          Sparkle 2.10.0 bin/ with generate_keys,
                               generate_appcast, and sign_update
  --download-url-prefix URL     HTTPS URL directory that will host the ZIP
  --release-notes PATH          Optional .md/.html/.txt notes embedded in the
                               signed appcast (requires --generate-appcast)

All three appcast options are required with --generate-appcast. The account's
public key must match the app. Private keys never leave the keychain. The app
must be a non-fixture release with HTTPS SUFeedURL, valid SUPublicEDKey,
SURequireSignedFeed=true, and SUVerifyUpdateBeforeExtraction=true.

Existing output files are never overwritten. Inspect the saved notarization
JSON on failure. Generated appcast.xml contains this release only; review it
before publishing or merging it into an existing feed. No deltas are generated.
HELP
}
usagebar_die() { print -u2 -- "$1"; exit 1; }
while (( $# )); do
  case "$1" in
    --help|-h) usagebar_help; exit 0 ;;
    --generate-appcast) usagebar_generate=1; shift ;;
    --app|--keychain-profile|--output-dir|--eddsa-account|--sparkle-tools|--download-url-prefix|--release-notes)
      (( $# >= 2 )) && [[ -n "$2" ]] || usagebar_die "Missing value for $1"
      case "$1" in
        --app) usagebar_app="$2" ;;
        --keychain-profile) usagebar_profile="$2" ;;
        --output-dir) usagebar_output="$2" ;;
        --eddsa-account) usagebar_account="$2" ;;
        --sparkle-tools) usagebar_tools="$2" ;;
        --download-url-prefix) usagebar_download_prefix="$2" ;;
        --release-notes) usagebar_notes="$2" ;;
      esac
      shift 2 ;;
    *) usagebar_die "Unknown option: $1 (use --help)" ;;
  esac
done
[[ -n "$usagebar_profile" ]] || usagebar_die "An existing --keychain-profile is required."
if [[ -n "$usagebar_notes" ]]; then
  [[ "$usagebar_generate" == 1 ]] || usagebar_die "--release-notes requires --generate-appcast."
  usagebar_notes="${usagebar_notes:A}"
  [[ -f "$usagebar_notes" && -r "$usagebar_notes" && -s "$usagebar_notes" ]] || usagebar_die "Release notes must be a readable, nonempty file."
  case "${usagebar_notes:e}" in
    md|html|txt) ;;
    *) usagebar_die "Release notes must use .md, .html, or .txt." ;;
  esac
fi
usagebar_python="$(command -v python3)"
usagebar_support="$usagebar_root/scripts/release-support.py"
usagebar_app="${usagebar_app:A}"
[[ -d "$usagebar_app" ]] || usagebar_die "App bundle does not exist: $usagebar_app"
"$usagebar_python" "$usagebar_support" release-config "$usagebar_app"
"$usagebar_python" "$usagebar_support" verify-developer "$usagebar_app"

if [[ "$usagebar_generate" == 1 ]]; then
  [[ -n "$usagebar_account" && -n "$usagebar_tools" && -n "$usagebar_download_prefix" ]] || usagebar_die "Appcast generation requires --eddsa-account, --sparkle-tools, and --download-url-prefix."
  usagebar_tools="${usagebar_tools:A}"
  for usagebar_tool in generate_keys generate_appcast sign_update; do
    [[ -x "$usagebar_tools/$usagebar_tool" ]] || usagebar_die "Missing Sparkle tool: $usagebar_tool"
  done
  "$usagebar_python" "$usagebar_support" https-url "$usagebar_download_prefix"
  [[ "$usagebar_download_prefix" == */ ]] || usagebar_die "--download-url-prefix must end in /"
  "$usagebar_python" "$usagebar_support" key-match "$usagebar_app" "$usagebar_tools" "$usagebar_account"
else
  [[ -z "$usagebar_account$usagebar_tools$usagebar_download_prefix" ]] || usagebar_die "Appcast options require --generate-appcast."
fi

usagebar_short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$usagebar_app/Contents/Info.plist")"
usagebar_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$usagebar_app/Contents/Info.plist")"
usagebar_name="UsageBar-$usagebar_short-$usagebar_build"
usagebar_output="${usagebar_output:-$usagebar_root/build/releases/$usagebar_short-$usagebar_build}"
usagebar_output="${usagebar_output:A}"
mkdir -p "$usagebar_output"
for usagebar_file in "$usagebar_name.zip" "$usagebar_name.notary.json"; do
  [[ ! -e "$usagebar_output/$usagebar_file" ]] || usagebar_die "Output already exists: $usagebar_output/$usagebar_file"
done
[[ "$usagebar_generate" == 0 || ! -e "$usagebar_output/appcast.xml" ]] || usagebar_die "Output already exists: $usagebar_output/appcast.xml"
usagebar_stage="$(mktemp -d "$usagebar_output/.usagebar-release.XXXXXX")"
trap 'rm -rf -- "$usagebar_stage"' EXIT
usagebar_copy="$usagebar_stage/UsageBar.app"
/usr/bin/ditto "$usagebar_app" "$usagebar_copy"
"$usagebar_python" "$usagebar_support" verify-developer "$usagebar_copy"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$usagebar_copy" "$usagebar_stage/submission.zip"
usagebar_report="$usagebar_output/$usagebar_name.notary.json"
print -- "Submitting to Apple notarization; result: $usagebar_report"
/usr/bin/xcrun notarytool submit "$usagebar_stage/submission.zip" \
  --keychain-profile "$usagebar_profile" --wait --output-format json > "$usagebar_report"
"$usagebar_python" "$usagebar_support" notarization-status "$usagebar_report"
/usr/bin/xcrun stapler staple "$usagebar_copy"
/usr/bin/xcrun stapler validate "$usagebar_copy"
/usr/sbin/spctl --assess --type execute --verbose=2 "$usagebar_copy"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$usagebar_copy"
mkdir -p "$usagebar_stage/archives"
usagebar_archive="$usagebar_stage/archives/$usagebar_name.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$usagebar_copy" "$usagebar_archive"

if [[ "$usagebar_generate" == 1 ]]; then
  usagebar_feed="$usagebar_stage/archives/appcast.xml"
  if [[ -n "$usagebar_notes" ]]; then
    cp "$usagebar_notes" "$usagebar_stage/archives/$usagebar_name.${usagebar_notes:e}"
  fi
  "$usagebar_tools/generate_appcast" --account "$usagebar_account" \
    --download-url-prefix "$usagebar_download_prefix" --maximum-deltas 0 --embed-release-notes \
    -o "$usagebar_feed" "$usagebar_stage/archives"
  "$usagebar_tools/sign_update" --account "$usagebar_account" --verify "$usagebar_feed"
  usagebar_signature="$("$usagebar_python" "$usagebar_support" appcast-signature "$usagebar_feed" "$usagebar_archive" "$usagebar_build")"
  "$usagebar_tools/sign_update" --account "$usagebar_account" --verify "$usagebar_archive" "$usagebar_signature"
  mv "$usagebar_feed" "$usagebar_output/appcast.xml"
fi
mv "$usagebar_archive" "$usagebar_output/$usagebar_name.zip"
print -- "Prepared: $usagebar_output/$usagebar_name.zip"
[[ "$usagebar_generate" == 0 ]] || print -- "Signed appcast: $usagebar_output/appcast.xml"
print -- "No public upload was performed."
