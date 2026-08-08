#!/usr/bin/env bash
#
# 把 SwiftPM 编译产物打包成一个真正的 .app（菜单栏代理程序），并做 ad-hoc 签名，
# 这样 macOS 才会为它弹出「屏幕录制」授权弹窗并把授权持久化到 bundle id。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DisplayMixer"
APP_DIR="$ROOT/build/$APP_NAME.app"
INSTALL_DIR="/Applications/$APP_NAME.app"
BIN_DIR="$ROOT/.build/release"
BIN="$BIN_DIR/$APP_NAME"

echo "==> swift build -c release"
swift build -c release --disable-sandbox

if [ ! -f "$BIN" ]; then
    echo "error: binary not found at $BIN" >&2
    exit 1
fi

echo "==> assemble $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# 复制一份 entitlements 到包内（仅作记录，codesign 用 Resources 下的那份）
cp "$ROOT/Resources/DisplayMixer.entitlements" "$APP_DIR/Contents/Entitlements.plist"

echo "==> ad-hoc codesign"
codesign --force --deep --sign - \
    --entitlements "$ROOT/Resources/DisplayMixer.entitlements" \
    "$APP_DIR"

echo "==> install $INSTALL_DIR"
ditto "$APP_DIR" "$INSTALL_DIR"

echo "==> done: $APP_DIR"
echo "    installed: $INSTALL_DIR"
echo "    双击运行，或在 Finder 里右键打开（首次会从菜单栏图标进入）。"
