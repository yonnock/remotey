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
cp -R Web "$APP/Contents/Resources/Web"
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
    # SIGTERM: the agent quits in order and gives a window in the phone's shape its frame back. One that does
    # not end within 10 s is killed; its next start puts the window back (see ShapedFrame.swift).
    pkill -TERM -x Remotey 2>/dev/null || true
    waited=0
    while pgrep -x Remotey >/dev/null; do # `open` fails while the old instance is still quitting
        waited=$((waited + 1))
        if [ "$waited" -ge 100 ]; then pkill -KILL -x Remotey 2>/dev/null || true; fi
        sleep 0.1
    done
    rm -rf /Applications/Remotey.app
    ditto "$APP" /Applications/Remotey.app
    # Launch Services can still hold the replaced bundle for a moment and refuse with error -600.
    tries=0
    until open /Applications/Remotey.app 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 10 ]; then
            echo "Installiert, aber der Start schlug fehl. Von Hand starten: open /Applications/Remotey.app" >&2
            exit 1
        fi
        sleep 0.5
    done
    echo "Installiert und gestartet: /Applications/Remotey.app"
fi
