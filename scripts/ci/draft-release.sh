#!/usr/bin/env bash
# After a tag pushed by hand (the fallback when a merged run failed): drafts the release with
# generated notes for editing before publishing.
set -euo pipefail

notes="Unsigned build: the first time, open Reload, then click Open Anyway in System Settings ▸ Privacy & Security."
[[ $HAS_CERT == true && $HAS_NOTARY == true ]] && notes="Signed and notarized."
gh release create "$GITHUB_REF_NAME" build/release/Reload-*.dmg* build/release/Reload-*.zip* \
  --draft --title "Reload $VERSION" --generate-notes --notes "$notes"
