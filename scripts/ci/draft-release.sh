#!/usr/bin/env bash
# After a tag pushed by hand (the fallback when a merged run failed): drafts the release with
# generated notes for editing before publishing. The Sparkle feed is attached when the key
# exists, with no notes; replace it with `scripts/appcast.sh <version> notes.md` if wanted.
set -euo pipefail

feed=()
if [[ -n ${SPARKLE_ED_PRIVATE_KEY:-} ]]; then
  scripts/appcast.sh "$VERSION"
  feed=(build/release/appcast.xml)
fi

notes="Unsigned build: the first time, open Reload, then click Open Anyway in System Settings ▸ Privacy & Security."
[[ $HAS_CERT == true && $HAS_NOTARY == true ]] && notes="Signed and notarized."
gh release create "$GITHUB_REF_NAME" build/release/Reload-*.dmg* build/release/Reload-*.zip* ${feed[@]+"${feed[@]}"} \
  --draft --title "Reload $VERSION" --generate-notes --notes "$notes"
