#!/usr/bin/env bash
# Is the caret actually painted? GUI check for changes to the editor's restyle,
# layout or widget pass (see CONTRIBUTING). Needs Screen Recording and
# Accessibility access for the terminal, and a Mac left alone for ~3 minutes:
# it takes the focus, and a run in which Hanji loses it is worthless.
#
#   ./scripts/caret-probe.sh [Hanji.app] [scenarios]      # default: ./Hanji.app, "plain mixed ends"
#
# Builds a copy of the app with its own bundle id (so the test vaults stay out
# of your Hanji's recent vaults), writes a long plain note and a long note full
# of widgets, drives each with key events sent to that process only, and after
# each step counts the frames (of 10, 2.5s) that show a caret. A healthy caret
# blinks: ~6-9 of 10. 0 means it wasn't painted; x/y with y < 10 means Hanji
# lost the focus for some frames (they don't count).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-./Hanji.app}"
WORK="$(mktemp -d /tmp/hanji-caret.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O scripts/caret-probe/main.swift -o "$WORK/probe"
cp -R "$APP" "$WORK/Probe.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.hanji.caretprobe' "$WORK/Probe.app/Contents/Info.plist"
codesign -s - --force --deep "$WORK/Probe.app" 2>/dev/null
mkdir -p "$WORK/plain" "$WORK/mixed" "$WORK/ends"
python3 - "$WORK" <<'PY'
import sys
w = sys.argv[1]
plain = []
for i in range(1000): plain += [f"## Section {i}", f"Paragraph {i} with **bold** text and more words to wrap a little.", "- item", ""]
open(w + '/plain/AAA.md', 'w').write("\n".join(plain))
open(w + '/ends/AAA.md', 'w').write("\n".join(plain))
mixed = []
for i in range(300):
    mixed += [f"## Part {i}", f"Some prose for part {i}, **bold** and *italic*.", "- list item", "- [ ] a task", ""]
    if i % 3 == 0: mixed += ["```swift", f"let value{i} = {i}", "print(value)", "```", ""]
    if i % 4 == 1: mixed += ["---", ""]
    if i % 7 == 2: mixed += ["| a | b |", "|---|---|", f"| {i} | x |", ""]
open(w + '/mixed/AAA.md', 'w').write("\n".join(mixed))
PY
for sc in ${2:-plain mixed ends}; do
  echo "== $sc"
  "$WORK/probe" "$WORK/Probe.app" "$WORK/$sc" "$sc" 2>&1 | grep -E ' caret ' || true
done
if pgrep -f "$WORK/Probe.app" >/dev/null; then echo "!! a probe app is still running"; fi
