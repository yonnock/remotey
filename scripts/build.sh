#!/bin/sh
# Builds build/Remotey.app and signs it with a stable identity, so macOS keeps the
# Accessibility permission across rebuilds. `--install` copies it to /Applications and starts it.
set -eu
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Remotey.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Remotey "$APP/Contents/MacOS/Remotey"
cp Web/index.html Web/live-view.js Web/icon.png "$APP/Contents/Resources/"
cp Support/Info.plist "$APP/Contents/Info.plist"

IDENTITY=${REMOTEY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}
if [ -z "$IDENTITY" ]; then
    echo "Keine Signatur-Identität gefunden. REMOTEY_SIGN_IDENTITY setzen." >&2
    exit 1
fi
# Hardened runtime: no other process may load code into Remotey (DYLD_INSERT_LIBRARIES, task ports)
# and so borrow its Accessibility and Screen Recording permissions.
codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "Gebaut: $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x Remotey 2>/dev/null || true
    while pgrep -x Remotey >/dev/null; do sleep 0.1; done # `open` fails while the old instance is still quitting
    rm -rf /Applications/Remotey.app
    ditto "$APP" /Applications/Remotey.app
    open /Applications/Remotey.app
    echo "Installiert und gestartet: /Applications/Remotey.app"
fi
