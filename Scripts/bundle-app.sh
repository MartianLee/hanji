#!/usr/bin/env bash
set -euo pipefail

BIN_NAME="hanji"   # SwiftPM product name (also the CLI: `swift run hanji`)
APP_NAME="Hanji"   # what Finder, the Dock, and the menu bar show
CONFIG="release"

swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

APP="${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
  cp "$SCRIPT_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hanji</string>
  <key>CFBundleIdentifier</key><string>io.hanji.app</string>
  <key>CFBundleVersion</key><string>0.0.1</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleExecutable</key><string>hanji</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built ./$APP"
