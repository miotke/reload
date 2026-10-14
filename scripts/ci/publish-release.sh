#!/usr/bin/env bash
# After a merged release PR: tags the merge commit vX.Y.Z, publishes the release with the
# built files and the PR description ($BODY) as notes, then deletes the release branch
# ($HEAD_REF). Runs only after the build succeeded, so a failed run leaves no tag. A tag
# pushed with the workflow's token doesn't start the workflow again.
set -euo pipefail

tag=v$VERSION
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
  echo "::error::$tag already exists"
  exit 1
fi
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git tag -a "$tag" -m "Reload $VERSION"
git push origin "$tag"
# The notes are the PR description, minus the Claude Code attribution line.
printf '%s\n' "$BODY" | grep -v '^🤖 Generated with' > "$RUNNER_TEMP/notes.md"
gh release create "$tag" build/release/Reload-*.dmg* build/release/Reload-*.zip* \
  --verify-tag --latest --title "Reload $VERSION" --notes-file "$RUNNER_TEMP/notes.md"
git push origin --delete "$HEAD_REF" || true
