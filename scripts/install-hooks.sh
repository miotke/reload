#!/usr/bin/env bash
# Points this clone's git hooks at .githooks/, so the pre-push hook runs the UI tests.
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
# git opens the SSH connection before the pre-push hook and pushes over it afterwards; the
# UI tests leave it idle for minutes, long enough to be dropped. Keep-alives prevent that.
git config core.sshCommand "ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=40"
echo "Git hooks installed: .githooks/pre-push runs scripts/ui-tests.sh before pushes that change app or core code."
