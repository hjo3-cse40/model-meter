#!/bin/sh
# Build a Release ModelMeter.app and install it (no Xcode debugger).
# Usage: scripts/install-local.sh [destination]
# Default destination: $HOME/Applications
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DEST="${1:-$HOME/Applications}"
DERIVED="$ROOT/.derivedData"
APP="$DERIVED/Build/Products/Release/ModelMeter.app"

cd "$ROOT"
xcodebuild \
  -project ModelMeter.xcodeproj \
  -scheme ModelMeter \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -quiet \
  build

mkdir -p "$DEST"
killall ModelMeter 2>/dev/null || true
rm -rf "$DEST/ModelMeter.app"
cp -R "$APP" "$DEST/ModelMeter.app"
open "$DEST/ModelMeter.app"

echo "Installed $DEST/ModelMeter.app (Release, no debugger)."
echo "Quit any copy still running from Xcode. Use Launch at Login on this app."
