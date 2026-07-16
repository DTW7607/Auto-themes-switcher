#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT_DIR"
swift build -c release --product AutoThemeSwitcher
BIN_DIR="$(swift build -c release --show-bin-path)"

APP_DIR="$ROOT_DIR/.build/app/Auto Theme Switcher.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_DIR/AutoThemeSwitcher" "$MACOS_DIR/AutoThemeSwitcher"
cp "$ROOT_DIR/Config/Info.plist" "$CONTENTS_DIR/Info.plist"

IDENTITY="${CODE_SIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none \
  --entitlements "$ROOT_DIR/Config/AutoThemeSwitcher.entitlements" \
  --sign "$IDENTITY" "$APP_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
