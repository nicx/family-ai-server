#!/usr/bin/env bash
#
# Builds "Family AI Runner.app" (menu-bar app around the runner) and zips it.
#
#   Scripts/make-runner-app.sh <universal runner binary> <output zip>
#
# Called by build-runner.sh. Uses CODESIGN_IDENTITY (ad hoc without it).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$1"
ZIP="$2"
IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/Family AI Runner.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" -o "$TMP/app-$arch" "$ROOT/RunnerApp/main.swift"
done
lipo -create -output "$APP/Contents/MacOS/FamilyAIRunnerApp" "$TMP/app-arm64" "$TMP/app-x86_64"
sed "s/VERSION/$VERSION/" "$ROOT/RunnerApp/Info.plist" > "$APP/Contents/Info.plist"
cp "$RUNNER" "$APP/Contents/Resources/family-ai-runner"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"; fi

codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP/Contents/Resources/family-ai-runner"
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
