#!/usr/bin/env bash
# Imports the Developer ID certificate ($P12, base64, and $P12_PASSWORD) into a temporary
# keychain, and tells release.sh to sign with it (RELOAD_KEYCHAIN, RELOAD_TEAM_ID).
# cleanup-signing.sh deletes the keychain.
set -euo pipefail

keychain=$RUNNER_TEMP/signing.keychain-db
password=$(uuidgen)
echo "$P12" | base64 --decode > "$RUNNER_TEMP/cert.p12"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$RUNNER_TEMP/cert.p12" -k "$keychain" -P "$P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -k "$password" "$keychain"
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | xargs)
rm "$RUNNER_TEMP/cert.p12"
echo "RELOAD_KEYCHAIN=$keychain" >> "$GITHUB_ENV"
echo "RELOAD_TEAM_ID=$TEAM_ID" >> "$GITHUB_ENV"
