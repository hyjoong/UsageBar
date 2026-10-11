#!/usr/bin/env python3
"""Validation shared by UsageBar's build and private release preparation scripts."""
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_plist(path):
    with Path(path).open("rb") as stream:
        return plistlib.load(stream)


def validate_url(value, loopback=False):
    require(isinstance(value, str) and value and not any(c.isspace() for c in value), "Feed/download URL must be a nonempty URL without whitespace.")
    url = urlsplit(value)
    require(url.hostname and url.username is None and url.password is None and "#" not in value, "URL must have a hostname, without credentials or a fragment.")
    _ = url.port
    require(url.scheme == "https" or (loopback and url.scheme == "http" and url.hostname in {"localhost", "127.0.0.1", "::1"}), "Use HTTPS. HTTP is allowed only for an explicitly enabled DEBUG loopback fixture.")
    return url


def validate_public_key(key):
    require(isinstance(key, str), "SUPublicEDKey must be a base64 string.")
    decoded = base64.b64decode(key, validate=True)
    require(len(decoded) == 32 and base64.b64encode(decoded).decode("ascii") == key, "SUPublicEDKey must encode exactly 32 bytes with canonical base64.")


def validate_feed(info, required=False, loopback=False):
    feed, key = info.get("SUFeedURL"), info.get("SUPublicEDKey")
    if feed is None and key is None and not required:
        return
    require(feed is not None and key is not None, "SUFeedURL and SUPublicEDKey must both be configured.")
    validate_url(feed, loopback)
    validate_public_key(key)


def configure(path, mode, developer):
    info = read_plist(path)
    fixture = os.environ.get("USAGEBAR_UPDATE_TEST", "0") == "1"
    loopback = os.environ.get("USAGEBAR_ALLOW_LOOPBACK_FEED", "0") == "1"
    for flag in ("USAGEBAR_UPDATE_TEST", "USAGEBAR_ALLOW_LOOPBACK_FEED"):
        require(os.environ.get(flag, "0") in {"0", "1"}, flag + " must be 0 or 1.")
    overrides = {"USAGEBAR_FIXTURE_BUILD_VERSION": "CFBundleVersion", "USAGEBAR_FIXTURE_SHORT_VERSION": "CFBundleShortVersionString"}
    fixture_requested = fixture or loopback or any(key in os.environ for key in overrides)
    require(not fixture_requested or (fixture and mode == "debug" and developer == "0"), "Update fixtures, version overrides, and loopback require USAGEBAR_UPDATE_TEST=1, debug, and ad-hoc signing.")
    if fixture:
        info["CFBundleIdentifier"] = "dev.hyjoong.usagebar.updatetest"
        info["CFBundleName"] = "UsageBar Update Test"
        info["CFBundleDisplayName"] = "UsageBar Update Test"
        info["UsageBarUpdateTestMode"] = True
        info["SUEnableAutomaticChecks"] = False
        if loopback:
            info.setdefault("NSAppTransportSecurity", {})["NSAllowsLocalNetworking"] = True
    else:
        require(not info.get("UsageBarUpdateTestMode") and info.get("CFBundleIdentifier") != "dev.hyjoong.usagebar.updatetest", "Fixture Info.plist cannot be used for an ordinary build.")
    for environment, key in overrides.items():
        if environment in os.environ:
            value = os.environ[environment]
            require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value), environment + " must contain one to three numeric version components.")
            info[key] = value
    for environment, key in (("USAGEBAR_FEED_URL", "SUFeedURL"), ("USAGEBAR_PUBLIC_ED_KEY", "SUPublicEDKey")):
        if environment in os.environ:
            info[key] = os.environ[environment]
    validate_feed(info, loopback=loopback and fixture)
    if fixture and info.get("SUFeedURL"):
        require(urlsplit(info["SUFeedURL"]).hostname in {"localhost", "127.0.0.1", "::1"}, "Update fixtures must use a loopback feed, including HTTPS feeds.")
    info["UsageBarBuildConfiguration"] = mode
    with Path(path).open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=False)


def framework(root):
    candidates = []
    for xcframework in Path(root).rglob("Sparkle.xcframework"):
        for library in read_plist(xcframework / "Info.plist").get("AvailableLibraries", []):
            if library.get("SupportedPlatform") == "macos" and not library.get("SupportedPlatformVariant"):
                candidate = xcframework / library["LibraryIdentifier"] / library["LibraryPath"]
                if candidate.is_dir():
                    candidates.append(candidate)
    require(len(candidates) == 1, "Expected one macOS Sparkle.framework; set USAGEBAR_SPARKLE_ROOT explicitly if needed.")
    print(candidates[0])


def nested_targets(app):
    framework_path = Path(app) / "Contents/Frameworks/Sparkle.framework"
    version = framework_path / "Versions/Current"
    return [version / "XPCServices/Installer.xpc", version / "XPCServices/Downloader.xpc", version / "Autoupdate", version / "Updater.app", framework_path, Path(app)]


def bundle_layout(app):
    app = Path(app)
    framework_path = app / "Contents/Frameworks/Sparkle.framework"
    for item in ("Versions/Current", "Sparkle", "Resources", "Updater.app", "XPCServices"):
        path = framework_path / item
        require(path.is_symlink() and path.exists(), "Sparkle framework symlinks were not preserved: " + item)
    for item in ("Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater", "XPCServices/Installer.xpc/Contents/MacOS/Installer", "XPCServices/Downloader.xpc/Contents/MacOS/Downloader"):
        require(os.access(framework_path / "Versions/Current" / item, os.X_OK), "Missing or non-executable Sparkle component: " + item)
    executable = app / "Contents/MacOS/UsageBar"
    linked = subprocess.run(["/usr/bin/otool", "-L", str(executable)], check=True, text=True, capture_output=True).stdout
    load_commands = subprocess.run(["/usr/bin/otool", "-l", str(executable)], check=True, text=True, capture_output=True).stdout
    require("@rpath/Sparkle.framework/" in linked, "App is not linked to Sparkle through @rpath.")
    require("path @executable_path/../Frameworks " in load_commands, "Missing @executable_path/../Frameworks runtime search path.")


def signing_identity(requested):
    result = subprocess.run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], check=True, text=True, capture_output=True)
    identities = re.findall(r'\b([A-Fa-f0-9]{40})\s+"([^"]+)"', result.stdout)
    matches = [digest for digest, name in identities if (requested == name or requested.lower() == digest.lower()) and name.startswith("Developer ID Application:")]
    require(len(matches) == 1, "Signing identity must exactly match one valid Developer ID Application name or SHA-1 in the keychain.")
    print(matches[0])


def verify_developer(app):
    bundle_layout(app)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    teams = set()
    for target in nested_targets(app):
        display = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(target)], check=True, text=True, capture_output=True).stderr
        require("Authority=Developer ID Application:" in display, "Nested component needs a Developer ID Application signature: " + str(target))
        require(re.search(r"^CodeDirectory .*\(.*runtime.*\)", display, re.M), "Hardened runtime missing: " + str(target))
        require(re.search(r"^Timestamp=.+", display, re.M), "Secure timestamp missing: " + str(target))
        team = re.search(r"^TeamIdentifier=([A-Z0-9]+)$", display, re.M)
        require(team is not None, "Team identifier missing: " + str(target))
        teams.add(team.group(1))
        entitlements = subprocess.run(["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(target)], check=True, capture_output=True).stdout
        if entitlements.strip():
            require(not plistlib.loads(entitlements).get("com.apple.security.get-task-allow"), "Debug entitlement cannot be distributed: " + str(target))
    require(len(teams) == 1, "App and nested Sparkle components must use the same Developer ID team.")


def release_config(app):
    info = read_plist(Path(app) / "Contents/Info.plist")
    require(info.get("UsageBarBuildConfiguration") == "release" and not info.get("UsageBarUpdateTestMode") and info.get("CFBundleIdentifier") != "dev.hyjoong.usagebar.updatetest", "Only a non-fixture release build can be prepared for distribution.")
    validate_feed(info, required=True)
    require(info.get("SURequireSignedFeed") is True and info.get("SUVerifyUpdateBeforeExtraction") is True, "Release updates require signed feeds and verification before extraction.")
    for key in ("CFBundleVersion", "CFBundleShortVersionString"):
        require(isinstance(info.get(key), str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", info[key]), "Invalid release version: " + key)


def key_match(app, tools, account):
    key = subprocess.run([str(Path(tools) / "generate_keys"), "--account", account, "-p"], check=True, text=True, capture_output=True).stdout.strip()
    validate_public_key(key)
    require(key == read_plist(Path(app) / "Contents/Info.plist").get("SUPublicEDKey"), "Named keychain account's public key does not match this app's SUPublicEDKey.")


def notarization_status(path):
    result = json.loads(Path(path).read_text())
    require(result.get("status") == "Accepted", "Notarization was not accepted. Inspect the saved notary JSON and fetch its log with notarytool.")


def appcast_signature(feed, archive, version):
    namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    for item in ET.parse(feed).getroot().findall("./channel/item"):
        enclosure = item.find("enclosure")
        if enclosure is not None and (item.findtext(namespace + "version") or enclosure.get(namespace + "version")) == version:
            validate_url(enclosure.get("url"))
            require(Path(urlsplit(enclosure.get("url")).path).name == Path(archive).name, "Appcast archive URL does not match this release.")
            require(enclosure.get("length") == str(Path(archive).stat().st_size), "Appcast archive length does not match this release.")
            signature = enclosure.get(namespace + "edSignature", "")
            require(len(base64.b64decode(signature, validate=True)) == 64, "Appcast archive is missing its EdDSA signature.")
            print(signature)
            return
    raise ValueError("Generated appcast does not contain the release build number.")


if __name__ == "__main__":
    commands = {"configure": configure, "framework": framework, "bundle-layout": bundle_layout,
                "signing-identity": signing_identity, "verify-developer": verify_developer,
                "release-config": release_config, "key-match": key_match,
                "notarization-status": notarization_status, "appcast-signature": appcast_signature,
                "https-url": validate_url}
    try:
        require(len(sys.argv) > 1 and sys.argv[1] in commands, "Unknown release-support command.")
        commands[sys.argv[1]](*sys.argv[2:])
    except (ValueError, KeyError, OSError, TypeError, subprocess.CalledProcessError, plistlib.InvalidFileException, ET.ParseError) as error:
        print("UsageBar release check failed: " + str(error), file=sys.stderr)
        sys.exit(1)
