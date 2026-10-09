#!/usr/bin/env bash
# Tracking test for "Follow my words": does the prompter stay on the speaker at every size?
#
#   Tests/Tracking/run.sh            replay the saved recordings (seconds; records them first if missing)
#   Tests/Tracking/run.sh record     re-record with the real recognizer (about 3.5 minutes of real-time
#                                    audio); do this after changing recognition or the script matcher
#
# Needs macOS 26 for on-device speech recognition when recording. The first recording asks to allow
# Speech Recognition for your terminal. Output lives in .build/tracking. See main.swift for details.
set -euo pipefail
cd "$(dirname "$0")/../.."

WORK=".build/tracking"
mkdir -p "$WORK"
BIN="$WORK/tracking"

# Speech recognition requires an Info.plist with a usage description, even for a command-line tool.
cat > "$WORK/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.scrollinator.tracking-test</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Tracking test for The Scrollinator.</string>
</dict></plist>
PLIST

echo "==> Building the tracking test with the app's sources"
# Leaves out LAME (recording isn't under test), so no MP3 encoder needs to be built.
swiftc -O -swift-version 5 -o "$BIN" \
    $(ls Sources/Scrollinator/*.swift | grep -v ScrollinatorApp.swift) Tests/Tracking/main.swift \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$WORK/Info.plist"

if [[ "${1:-}" == record || ! -f "$WORK/in-order.json" || ! -f "$WORK/hard.json" ]]; then
    "$BIN" prepare "$WORK"
    "$BIN" record "$WORK" in-order
    "$BIN" record "$WORK" hard
fi

status=0
"$BIN" replay "$WORK" in-order || status=1
echo
"$BIN" replay "$WORK" hard || status=1
exit $status
