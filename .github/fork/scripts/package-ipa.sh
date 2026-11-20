#!/usr/bin/env bash
# Packages a built NOOP.app (iphoneos, Release, unsigned) into the fork's sideload IPA.
# Same steps as upstream's fork-release.yml iOS leg, plus the checks the VM 112 updater relies on.
# macOS only (PlistBuddy, codesign via Tools/prepare-ios-sideload-app.sh, shasum).
# Usage: package-ipa.sh <path/to/NOOP.app> <tag> <out-dir>
# Writes <out-dir>/NOOP-ios-extras-<tag>.ipa and <out-dir>/NOOP-ios-extras-<tag>.ipa.sha256
set -euo pipefail
APP="${1:?usage: package-ipa.sh <app> <tag> <out-dir>}"
TAG="${2:?usage: package-ipa.sh <app> <tag> <out-dir>}"
OUT="${3:?usage: package-ipa.sh <app> <tag> <out-dir>}"
EXPECTED_BUNDLE_ID="com.noopapp.noop"

[ -d "$APP" ] || { echo "::error::no app bundle at $APP"; exit 1; }
rm -rf "$APP/Watch"
[ -d "$APP/PlugIns/NOOPWidgets.appex" ] || { echo "::error::NOOPWidgets.appex missing from iOS build"; exit 1; }
BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
[ "$BID" = "$EXPECTED_BUNDLE_ID" ] || { echo "::error::bundle id is $BID, expected $EXPECTED_BUNDLE_ID"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")
echo "bundle $BID version $VER"

Tools/prepare-ios-sideload-app.sh "$APP"

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
NAME="NOOP-ios-extras-${TAG}.ipa"
WORK=$(mktemp -d)
mkdir "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
(cd "$WORK" && zip -qr "$OUT/$NAME" Payload)
rm -rf "$WORK"
(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256" && cat "$NAME.sha256")
