#!/bin/bash
set -euo pipefail
LENS_REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$LENS_REPO"
if [[ "$(uname -s)" == "Linux" ]]; then exec bash scripts/build-linux.sh; fi
swift build --configuration release
LENS_BIN="$(swift build --configuration release --show-bin-path)"
LENS_APP="$LENS_REPO/dist/Native Browser Lens.app"
mkdir -p "$LENS_APP/Contents/MacOS" "$LENS_APP/Contents/Resources"
cp "$LENS_BIN/NativeBrowserLens" "$LENS_APP/Contents/MacOS/NativeBrowserLens"
cp "$LENS_BIN/lens-host" "$LENS_APP/Contents/MacOS/lens-host"
cp "$LENS_REPO/packaging/Info.plist" "$LENS_APP/Contents/Info.plist"
codesign --force --sign - --identifier studio.sirv.native-browser-lens.host "$LENS_APP/Contents/MacOS/lens-host"
codesign --force --sign - --identifier studio.sirv.native-browser-lens --entitlements "$LENS_REPO/packaging/entitlements.plist" "$LENS_APP"
npm --prefix extension run build
echo "$LENS_APP"
