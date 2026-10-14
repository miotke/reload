#!/usr/bin/env bash
# One kind of check, as CI runs it: `docs`, `core` (core and CLI) or `app`. Timing budgets
# follow RELOAD_PERF_SLACK, which the workflows set to 3 (docs/development.md).
set -euo pipefail

case ${1:-} in
  docs)
    swift scripts/check-docs.swift
    ;;
  core)
    swift test
    ;;
  app)
    # xcodebuild passes TEST_RUNNER_* variables to the tests without the prefix.
    export TEST_RUNNER_RELOAD_PERF_SLACK=${RELOAD_PERF_SLACK:-1}
    xcodebuild -project App/Reload.xcodeproj -scheme Reload -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath build/DerivedData test \
      | grep -v 'CUICatalog'
    ;;
  *)
    echo "usage: $0 docs|core|app" >&2
    exit 2
    ;;
esac
