#!/usr/bin/env bash
# Deletes the temporary keychain and notarization key, whatever happened before.
set -uo pipefail

[[ -n ${RELOAD_KEYCHAIN:-} ]] && security delete-keychain "$RELOAD_KEYCHAIN"
rm -f "$RUNNER_TEMP/notary.p8"
exit 0
