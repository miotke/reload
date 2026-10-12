#!/bin/sh
# Renders the app's key views to build/snapshots/<name>-<light|dark>.png (docs/development.md#snapshots).
# Run from anywhere; it uses the repo root. View the PNGs after any UI change.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [ -z "${DEVELOPER_DIR:-}" ] && xcode-select -p | grep -q CommandLineTools; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

rm -rf build/snapshots
xcodebuild -project App/ForeverAddons.xcodeproj -scheme ForeverAddons -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build/DerivedData \
    test -only-testing:ForeverAddonsTests/SnapshotTests -quiet

echo "Snapshots in $root/build/snapshots:"
ls -1 build/snapshots
