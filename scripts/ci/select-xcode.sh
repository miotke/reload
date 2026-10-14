#!/usr/bin/env bash
# Selects the newest Xcode 26 or later on a GitHub macOS runner: the project needs Swift 6.2
# and the macOS 26 SDK.
set -euo pipefail

xcode=$(ls -d /Applications/Xcode_2[6-9]*.app 2>/dev/null | sort -V | tail -1 || true)
if [[ -z $xcode ]]; then
  echo "::error::This runner has no Xcode 26 or later. Installed: $(ls -d /Applications/Xcode*.app | xargs)"
  exit 1
fi
sudo xcode-select -s "$xcode"
xcodebuild -version
