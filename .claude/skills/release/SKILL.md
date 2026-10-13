---
name: release
description: Bump Reload's version on a branch and open a PR for it; after the PR merges, tag it and draft the GitHub release with the DMG and zip.
argument-hint: "[version | patch | minor | major | publish]"
disable-model-invocation: true
---

# Release Reload

Two phases. Full background: `docs/app/releases.md`.

- `/release`, `/release patch|minor|major` or `/release 0.3.0`: **prepare**, which opens a version-bump PR.
- `/release publish`: run after that PR is merged. Tags `main` and drafts the GitHub release.

Signed tags need a message (`tag.gpgsign` is on), so always `git tag -m`. Commits get only the `Co-Authored-By` trailer, never a `Claude-Session` line. Commit subjects are lowercase, imperative, under 60 characters.

## Prepare

1. `git fetch --tags origin`. Stop if the working tree isn't clean, then `git switch main && git pull --ff-only`.
2. Find the current version: `git tag --list 'v*' --sort=-v:refname | head -1`, and check it against `AppInfo.version` in `Sources/AddonKit/Sources/Source.swift`.
3. Work out the new version: the argument if it's `X.Y.Z`, otherwise bump `patch` (the default), `minor` or `major`. Stop if the tag `vX.Y.Z` already exists.
4. `git switch -c release/vX.Y.Z`.
5. Update every version number:
   - `App/project.yml`: `CFBundleShortVersionString: "X.Y.Z"`, and `CFBundleVersion` plus one
   - `App/Reload/Info.plist`: the same two keys (`/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString X.Y.Z' -c 'Set :CFBundleVersion N'`)
   - `Sources/AddonKit/Sources/Source.swift`: `AppInfo.version`
   - Then `rg -n '<old version>' --glob '!build' --glob '!docs/decisions'` and fix any other copy that describes the current version, not history.
6. Check, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:
   - `swift test`
   - `swift scripts/check-docs.swift`
   - `scripts/release.sh X.Y.Z`, which also confirms the three versions match and that the DMG builds
   Report any failure plainly, and stop.
7. Commit `bump version to X.Y.Z`, then `git push -u origin release/vX.Y.Z`.
8. Open the PR: `gh pr create --base main --title "release X.Y.Z"`. The body has:
   - the changes since the last tag, from `git log --oneline vOLD..main`, grouped into a few plain-language bullets
   - a line saying that after merging, `/release publish` tags and drafts the release
   - the PR attribution footer from the session's instructions
9. Reply with the PR link and the version. Nothing else.

## Publish

1. `git switch main && git pull --ff-only`. Read the version from `AppInfo.version`. Stop if `vX.Y.Z` already exists, or if `git log --oneline --grep 'bump version to X.Y.Z'` finds nothing (the PR isn't merged yet).
2. `git tag -m "Reload X.Y.Z" vX.Y.Z && git push origin vX.Y.Z`. The tag starts the Release workflow.
3. GitHub's runners don't have Xcode 27 yet (see `docs/app/releases.md`). Watch the run with `gh run list --workflow release.yml -L 1`. If it failed at "Select Xcode 27", build here instead:
   ```sh
   scripts/release.sh X.Y.Z
   gh release create vX.Y.Z build/release/Reload-X.Y.Z.dmg* build/release/Reload-X.Y.Z.zip* \
     --draft --verify-tag --title "Reload X.Y.Z" --generate-notes \
     --notes "Unsigned build: right-click Reload.app and choose Open the first time. Requires macOS 27 on Apple silicon."
   ```
   If it passed, the workflow already drafted the release; don't create a second one.
4. Reply with the draft link, and remind the user to publish it on GitHub. Never publish it yourself.
