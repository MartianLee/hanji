#!/usr/bin/env bash
# Build Hanji.app from the SwiftPM release build.
#
#   ./Scripts/bundle-app.sh                    # ad-hoc signed, runs on this Mac
#   SIGN_ID="Developer ID Application: …" ./Scripts/bundle-app.sh
#                                              # Developer ID + hardened runtime,
#                                              # ready for notarization
#
# VERSION defaults to the latest v* tag (without the "v"), else 0.1.0; the
# build number is the commit count, so every build from main increases it.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_NAME="hanji"   # SwiftPM product name (also the CLI: `swift run hanji`)
APP_NAME="Hanji"   # what Finder, the Dock, and the menu bar show
CONFIG="release"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c "$CONFIG" --product "$BIN_NAME"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

APP="${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp Scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hanji</string>
  <key>CFBundleDisplayName</key><string>Hanji</string>
  <key>CFBundleIdentifier</key><string>io.hanji.app</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleExecutable</key><string>hanji</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 MartianLee. MIT License.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [ -n "${SIGN_ID:-}" ]; then
  # Hardened runtime + secure timestamp: what notarization requires.
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "Built ./$APP ($VERSION, build $BUILD)"
