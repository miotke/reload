#!/usr/bin/env bash
# Points this clone's git hooks at .githooks/, so the pre-push hook runs the UI tests.
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
echo "Git hooks installed: .githooks/pre-push runs scripts/ui-tests.sh before pushes that change app or core code."
