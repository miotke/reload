#!/usr/bin/env bash
# After a merged release PR: tags the merge commit vX.Y.Z, publishes the release with the
# built files, the signed Sparkle feed (appcast.xml) and the description of PR $PR_NUMBER
# as notes, then deletes the release branch ($HEAD_REF). Runs only after the build
# succeeded, so a failed run leaves no tag. A tag pushed with the workflow's token doesn't
# start the workflow again.
set -euo pipefail

tag=v$VERSION
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
  echo "::error::$tag already exists"
  exit 1
fi
# The feed comes first, so a missing key fails the run before anything is tagged. Without it
# installed copies would find no update: they read the latest release's appcast.xml.
if [[ -z ${SPARKLE_ED_PRIVATE_KEY:-} ]]; then
  echo "::error::the release environment has no SPARKLE_ED_PRIVATE_KEY secret (docs/app/updates.md#signing-key)"
  exit 1
fi
# The notes are the PR description, minus the Claude Code attribution line.
gh pr view "$PR_NUMBER" --json body -q .body | grep -v '^🤖 Generated with' > "$RUNNER_TEMP/notes.md"
scripts/appcast.sh "$VERSION" "$RUNNER_TEMP/notes.md"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git tag -a "$tag" -m "Reload $VERSION"
git push origin "$tag"
gh release create "$tag" build/release/Reload-*.dmg* build/release/Reload-*.zip* build/release/appcast.xml \
  --verify-tag --latest --title "Reload $VERSION" --notes-file "$RUNNER_TEMP/notes.md"
git push origin --delete "$HEAD_REF" || true
