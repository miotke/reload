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

# UI tests need an unlocked screen: macOS won't bring the app to the front otherwise.
if [[ $(ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers.0.CGSSessionScreenIsLocked raw - 2>/dev/null) == true ]]; then
  echo "The screen is locked. Unlock this Mac and run this again: UI tests can't drive a locked screen." >&2
  exit 1
fi

# The test runner is sandboxed, so it can't examine the app it drives. It writes the app's
# process ID to <label>.request in its own temp folder; this measures the app with `leaks`,
# `footprint` and `heap`, and writes "<leaked bytes> <footprint bytes> <live heap bytes>" to <label>.result.
runner_tmp="$HOME/Library/Containers/io.github.miotke.ReloadUITests.xctrunner/Data/tmp"
measure_dir="$runner_tmp/ReloadUITests-measure"
# Failed runs leave their throwaway data folders behind; start clean.
rm -rf "$runner_tmp"/ReloadUITests-*

bytes() {  # "52.3 MB" -> bytes
  awk -v n="$1" -v u="$2" 'BEGIN { m = (u == "KB") ? 1024 : (u == "MB") ? 1048576 : (u == "GB") ? 1073741824 : 1; printf "%.0f", n * m }'
}

measure_requests() {
  set +e
  while true; do
    for request in "$measure_dir"/*.request; do
      [[ -e $request ]] || continue
      pid=$(cat "$request")
      # `leaks` exits 1 whenever it finds any (Apple's constant one included), so no -e here.
      leaked=0
      # round-N requests only want the footprint; `leaks` takes a while.
      [[ $(basename "$request") == round-* || $(basename "$request") == step-* || $(basename "$request") == browse-* ]] || leaked=$(leaks "$pid" 2>/dev/null | sed -nE 's/.* leaks? for ([0-9]+) total leaked bytes.*/\1/p' | head -1 || true)
      report=$(footprint -p "$pid" 2>/dev/null || true)
      read -r amount unit < <(awk '/phys_footprint:/ { print $2, $3; exit }' <<< "$report") || true
      read -r peak_amount peak_unit < <(awk '/phys_footprint_peak:/ { print $2, $3; exit }' <<< "$report") || true
      # Diagnostics: RELOAD_UI_SNAPSHOT_ROUNDS="7 9" saves vmmap and heap at those rounds;
      # with --steps, "step-9 step-16" works too.
      label=$(basename "${request%.request}")
      for round in ${RELOAD_UI_SNAPSHOT_ROUNDS:-}; do
        if [[ $label == "round-$round" || $label == "$round" ]]; then
          mkdir -p build/ui-snapshots
          vmmap --summary "$pid" > "build/ui-snapshots/$label-vmmap.txt" 2>&1
          heap "$pid" > "build/ui-snapshots/$label-heap.txt" 2>&1
        fi
      done
      # Live heap bytes: what the app's objects actually hold, unlike the footprint, which
      # also counts freed memory the allocator hasn't returned yet.
      live=0
      [[ $(basename "$request") == round-* || $(basename "$request") == step-* || $(basename "$request") == browse-* ]] || live=$(heap "$pid" 2>/dev/null | sed -nE 's/^All zones: [0-9]+ nodes \(([0-9]+) bytes\).*/\1/p' | head -1 || true)
      # Diagnostics: RELOAD_UI_TRACE=SwiftUI records that Instruments template for 60 s from
      # the first step (with --steps) into build/instruments/ui.trace.
      if [[ -n ${RELOAD_UI_TRACE:-} && $label == step-1 ]]; then
        mkdir -p build/instruments && rm -rf build/instruments/ui.trace
        xcrun xctrace record --template "$RELOAD_UI_TRACE" --attach "$pid" --time-limit 60s \
          --output build/instruments/ui.trace > build/instruments/ui-trace.log 2>&1 &
        sleep 3
      fi
      result=${request%.request}.result
      echo "${leaked:-x} $(bytes "${amount:-0}" "${unit:-B}") ${live:-x} $(bytes "${peak_amount:-0}" "${peak_unit:-B}")" > "$result.tmp" && mv "$result.tmp" "$result"
      rm -f "$request"
    done
    sleep 1
  done
}
measure_requests &
watcher=$!
trap 'kill $watcher 2>/dev/null' EXIT

set -o pipefail
steps=()
[[ ${1:-} == --steps ]] && steps=(TEST_RUNNER_RELOAD_UI_STEPS=1)
env ${steps[@]+"${steps[@]}"} TEST_RUNNER_RELOAD_MEASURE=1 TEST_RUNNER_RELOAD_UI_ROUNDS=${RELOAD_UI_ROUNDS:-8} xcodebuild -project App/Reload.xcodeproj -scheme ReloadUITests -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData-UITests test \
  | grep -vE 'CUICatalog|linkd\.autoShortcut' \
  | grep -E 'Test Case|MemoryUITests|error:|failed|passed|TEST (SUCCEEDED|FAILED)|Executed'
