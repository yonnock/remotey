#!/bin/sh
# Pictures of the Mac's menu, assistant, settings and Face ID window, drawn off screen with made-up data, in light
# and dark. Nothing is shown on the display and the agent does not start.
#
#   scripts/mac-pictures.sh DIR                   the current sources
#   scripts/mac-pictures.sh --before COMMIT DIR   the interface of COMMIT (made for 23b8eae, before the panel),
#                                                 built in a temporary worktree that is removed afterwards
set -eu
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--before" ]; then
    commit=$2
    out=$(cd "$(dirname "$3")" && pwd)/$(basename "$3")
    temporary=$(mktemp -d)
    tree=$temporary/remotey-before
    git worktree add --detach "$tree" "$commit" >/dev/null
    trap 'git worktree remove --force "$tree"; rm -rf "$temporary"' EXIT
    cp Tests/RemoteyTests/Pictures.swift scripts/pictures/BeforePicturesTests.swift "$tree/Tests/RemoteyTests/"
    # The Face ID window kept its view to itself; the picture needs it without ordering the window in.
    sed -i '' 's/private lazy var content/lazy var content/' "$tree/Sources/Remotey/FaceUnlockWindow.swift"
    (cd "$tree" && REMOTEY_PICTURES="$out" swift test --filter BeforePicturesTests)
else
    out=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
    REMOTEY_PICTURES="$out" swift test --filter InterfacePicturesTests
fi
echo "Bilder in $out"
