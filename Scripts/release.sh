#!/usr/bin/env bash
# Build a release zip of Hanji.app and its release notes into dist/.
#
#   VERSION=0.1.0 ./Scripts/release.sh
#
# Optional, for a Gatekeeper-friendly build (all three notary vars together):
#   SIGN_ID          "Developer ID Application: Name (TEAMID)"
#   NOTARY_APPLE_ID  Apple ID used for notarization
#   NOTARY_TEAM_ID   Team ID
#   NOTARY_PASSWORD  app-specific password
# Without SIGN_ID the app is signed ad-hoc and the notes say how to open it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?set VERSION, e.g. VERSION=0.1.0}"
export VERSION
DIST="dist"
ZIP="$DIST/Hanji-$VERSION.zip"
rm -rf "$DIST" && mkdir -p "$DIST"

swift run Checks
./Scripts/bundle-app.sh

# Notarize + staple when signed with a Developer ID and credentials are present.
if [ -n "${SIGN_ID:-}" ] && [ -n "${NOTARY_APPLE_ID:-}" ]; then
  ditto -c -k --keepParent Hanji.app "$DIST/notarize.zip"
  xcrun notarytool submit "$DIST/notarize.zip" --wait \
    --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD"
  xcrun stapler staple Hanji.app
  rm "$DIST/notarize.zip"
  NOTARIZED=1
fi
ditto -c -k --keepParent Hanji.app "$ZIP"

# Release notes: this version's CHANGELOG section, plus how to open the app.
awk -v v="$VERSION" '
  $0 ~ "^## \\[" v "\\]" { on = 1; next }
  on && /^## \[/ { exit }
  on && /^\[[^]]*\]: / { next }   # link references at the end of the file
  on { print }
' CHANGELOG.md > "$DIST/notes.md"
[ -s "$DIST/notes.md" ] || { echo "CHANGELOG.md has no section for $VERSION" >&2; exit 1; }
if [ -z "${NOTARIZED:-}" ]; then
  cat >> "$DIST/notes.md" <<'NOTES'

### Opening the app
This build isn't notarized yet, so macOS blocks it on first launch. Unzip it,
move **Hanji.app** to Applications, then either run
`xattr -dr com.apple.quarantine /Applications/Hanji.app` in Terminal, or try to
open it once and choose **Open Anyway** in System Settings ▸ Privacy & Security.
NOTES
fi

shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "Release artifacts in $DIST/: $(ls "$DIST" | tr '\n' ' ')"
