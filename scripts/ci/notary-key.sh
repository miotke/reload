#!/usr/bin/env bash
# Writes the App Store Connect key ($P8) to a file and tells release.sh to notarize with it.
# cleanup-signing.sh deletes the file.
set -euo pipefail

echo "$P8" > "$RUNNER_TEMP/notary.p8"
echo "RELOAD_NOTARY_KEY_PATH=$RUNNER_TEMP/notary.p8" >> "$GITHUB_ENV"
echo "RELOAD_NOTARY_KEY_ID=$NOTARY_KEY_ID" >> "$GITHUB_ENV"
echo "RELOAD_NOTARY_ISSUER_ID=$NOTARY_ISSUER_ID" >> "$GITHUB_ENV"
