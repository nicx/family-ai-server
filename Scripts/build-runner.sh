#!/usr/bin/env bash
#
# Builds Family AI Runner for Windows, macOS and Linux into dist/runner/ (needs Go).
#
#   CODESIGN_IDENTITY="nicx Selfsign" ./Scripts/build-runner.sh
#
# The macOS binary is universal (arm64 + x86_64) and signed with CODESIGN_IDENTITY
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

build() { # goos goarch output
  echo "==> $1/$2"
  CGO_ENABLED=0 GOOS="$1" GOARCH="$2" go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "$3" .
}

build windows amd64 "$OUT/family-ai-runner-windows-x64.exe"
build windows arm64 "$OUT/family-ai-runner-windows-arm64.exe"
build linux amd64 "$OUT/family-ai-runner-linux-x64"
build linux arm64 "$OUT/family-ai-runner-linux-arm64"
TMP="$(mktemp -d)"
build darwin arm64 "$TMP/arm64"
build darwin amd64 "$TMP/amd64"
lipo -create -output "$OUT/family-ai-runner-macos" "$TMP/arm64" "$TMP/amd64"
rm -rf "$TMP"
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$OUT/family-ai-runner-macos"

(cd "$OUT" && shasum -a 256 family-ai-runner-* > SHA256SUMS)
echo "==> Done: $OUT"
ls -lh "$OUT"
