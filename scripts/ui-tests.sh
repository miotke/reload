#!/usr/bin/env bash
# Runs the UI tests (App/ReloadUITests): a throwaway copy of Reload driven through its main
# screens, failing on leaks or memory growth (docs/development.md#ui-tests). Not run in CI;
# the pre-push hook (.githooks/pre-push) runs this before each push.
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ $(xcode-select -p) == */CommandLineTools ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# XCTest quits any running copy of the app it launches, so never start over the user's.
if pgrep -xq Reload; then
  echo "Reload is running. Quit it (every copy) and run this again: the UI tests would quit it." >&2
  exit 1
fi

set -o pipefail
xcodebuild -project App/Reload.xcodeproj -scheme ReloadUITests -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData-UITests test \
  | grep -vE 'CUICatalog|linkd\.autoShortcut' \
  | grep -E 'Test Case|MemoryUITests:|error:|failed|passed|TEST (SUCCEEDED|FAILED)|Executed'
