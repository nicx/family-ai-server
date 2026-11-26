#!/usr/bin/env bash
#
# Builds Family AI Runner into dist/runner/ (needs Go): Windows taskbar apps, macOS menu-bar app (zip), Linux programs.
#
#   CODESIGN_IDENTITY="nicx Selfsign" ./Scripts/build-runner.sh
#
# The macOS runner inside the app is universal (arm64 + x86_64) and signed with CODESIGN_IDENTITY
# (ad hoc without it). Windows binaries are unsigned: SmartScreen asks once.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist/runner"
IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"

command -v go >/dev/null || { echo "Go fehlt (brew install go)" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
cd "$ROOT/Runner"
go test ./...

# Build stamp (UTC): compiled into every binary and published as runner-build; a runner with an older stamp updates itself.
STAMP="$(date -u +%Y%m%d%H%M%S)"
echo "$STAMP" > "$OUT/runner-build"

build() { # goos goarch output
  echo "==> $1/$2"
  CGO_ENABLED=0 GOOS="$1" GOARCH="$2" go build -trimpath -ldflags "-s -w -X main.version=$VERSION -X main.build=$STAMP" -o "$3" .
}

buildtray() { # goarch output – Windows taskbar app: no console window
  echo "==> windows/$1 (taskbar app)"
  CGO_ENABLED=0 GOOS=windows GOARCH="$1" go build -trimpath -tags tray -ldflags "-s -w -H=windowsgui -X main.version=$VERSION -X main.build=$STAMP" -o "$2" .
}
buildtray amd64 "$OUT/family-ai-runner-tray-windows-x64.exe"
buildtray arm64 "$OUT/family-ai-runner-tray-windows-arm64.exe"
build linux amd64 "$OUT/family-ai-runner-linux-x64"
build linux arm64 "$OUT/family-ai-runner-linux-arm64"
TMP="$(mktemp -d)"
build darwin arm64 "$TMP/arm64"
build darwin amd64 "$TMP/amd64"
# Thin, signed copies for the self-update of the menu-bar app (it picks the one for its architecture).
cp "$TMP/arm64" "$OUT/family-ai-runner-macos-arm64"
cp "$TMP/amd64" "$OUT/family-ai-runner-macos-x64"
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$OUT/family-ai-runner-macos-arm64"
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$OUT/family-ai-runner-macos-x64"
lipo -create -output "$TMP/family-ai-runner-macos" "$TMP/arm64" "$TMP/amd64"
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$TMP/family-ai-runner-macos"
echo "==> macOS menu-bar app"
"$ROOT/Scripts/make-runner-app.sh" "$TMP/family-ai-runner-macos" "$OUT/family-ai-runner-macos-app.zip"
rm -rf "$TMP"

(cd "$OUT" && shasum -a 256 family-ai-runner-* > SHA256SUMS)
echo "==> Done: $OUT"
ls -lh "$OUT"
