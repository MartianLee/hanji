#!/usr/bin/env bash
# Happy-path E2E for Hanji — run after every feature addition.
#
#   ./Scripts/e2e.sh           # headless scenario + app launch smoke test
#   ./Scripts/e2e.sh --fast    # headless scenario only (skip bundle/launch)
#
# The scenario (Sources/Checks/E2EChecks.swift) drives the real stack —
# AppState + Host + plugins + filesystem — through: open vault → daily note
# from template (⌘P command) → new folder/note → rename → edit + save →
# fuzzy switcher → delete → external change picked up by the live watcher.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▶ headless E2E scenario"
swift run Checks E2E

if [ "${1:-}" = "--fast" ]; then exit 0; fi

echo "▶ bundle + launch smoke test"
./Scripts/bundle-app.sh >/dev/null

VAULT="$(mktemp -d /tmp/hanji-e2e-vault.XXXXXX)"
trap 'rm -rf "$VAULT"' EXIT
printf '# Smoke\nhello' > "$VAULT/Smoke.md"

HANJI_OPEN_VAULT="$VAULT" ./Hanji.app/Contents/MacOS/hanji &
APP_PID=$!
sleep 3
if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "❌ app exited within 3s of launch"
  exit 1
fi
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
echo "✅ app launched and stayed alive (E2E green)"
