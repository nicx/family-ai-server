#!/usr/bin/env bash
#
# Builds "dist/Family AI Server.app": release build of the Swift executable plus the web app.
#
#   CODESIGN_IDENTITY="nicx Selfsign" ./Scripts/make-app.sh
#
# Without CODESIGN_IDENTITY the bundle is signed ad hoc ("-"); macOS then forgets
# permissions (local network, notifications) after every rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Family AI Server.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

# Never replace a running bundle (the app runs from dist/).
RUNNING="$(pgrep -f "$APP/Contents/MacOS/FamilyAIServer" || true)"
if [[ -n "$RUNNING" ]]; then
  echo "ABBRUCH: Family AI Server läuft gerade aus $ROOT/dist (PID: ${RUNNING//$'\n'/ }). Erst beenden, dann bauen." >&2
  exit 1
fi

cd "$ROOT"
echo "==> Building release executable"
swift build -c release --product FamilyAIServer
BIN="$(swift build -c release --product FamilyAIServer --show-bin-path)/FamilyAIServer"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/FamilyAIServer"
cp -R Web "$APP/Contents/Resources/Web"

echo "==> Building Family AI Runner (served for download under /runner/)"
CODESIGN_IDENTITY="$IDENTITY" "$ROOT/Scripts/build-runner.sh"
cp -R "$ROOT/dist/runner" "$APP/Contents/Resources/Web/runner"

if [[ -f Resources/AppIcon-1024.png ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Code signing (identity: $IDENTITY)"
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP/Contents/MacOS/FamilyAIServer"
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "==> Done: $APP"
