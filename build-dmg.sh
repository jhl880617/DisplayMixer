#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DisplayMixer"
VERSION="1.1.0"
APP_DIR="$ROOT/build/$APP_NAME.app"
DMG_DIR="$ROOT/build/dmg"
DMG_PATH="$ROOT/build/$APP_NAME-$VERSION.dmg"

if [ ! -d "$APP_DIR" ]; then
    "$ROOT/build-app.sh"
fi

rm -rf "$DMG_DIR" "$DMG_PATH"
mkdir -p "$DMG_DIR"
ditto "$APP_DIR" "$DMG_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_DIR/应用程序"

hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$DMG_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

echo "==> done: $DMG_PATH"
