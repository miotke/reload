---
name: release
description: Start a release branch for the next Reload version, keep its PR's release notes current, and after the PR merges tag, build and publish the release.
argument-hint: "[start [version | patch | minor | major] | notes | publish]"
disable-model-invocation: true
---

# Release Reload

Every change for a version lands on `release/vX.Y.Z`. Its pull request into `main` carries the release notes in its description. Merging that PR is the release: a workflow tags, builds and publishes the merge commit. Full background: `docs/app/releases.md`, [decision 0027](../../../docs/decisions/0027-release-branches.md).

- `/release start`, `/release start patch|minor|major` or `/release start 0.3.0`: open the next release branch and its PR.
- `/release notes`: rewrite the PR description from what's on the branch.
- `/release publish`: after the PR is merged, check the automatic release, or finish it by hand if the run failed.
- `/release` with no argument: `notes` if a `release/v*` branch is open, otherwise `start`.

The branch is `release/vX.Y.Z`, never `vX.Y.Z`: a branch and a tag with the same name make git refs ambiguous.

Signed tags need a message (`tag.gpgsign` is on), so always `git tag -m`. Commits get only the `Co-Authored-By` trailer, never a `Claude-Session` line. Commit subjects are lowercase, imperative, under 60 characters.

When `xcode-select -p` points at the Command Line Tools, set `DEVELOPER_DIR` to an installed Xcode 26 or later (`ls -d /Applications/Xcode*.app`) for every build and test below.

## Start

1. `git fetch --tags origin`. Stop if the working tree isn't clean. Stop if a `release/v*` branch is already open (`gh pr list --head 'release/' --state open` or `git branch -r --list 'origin/release/*'`): there is one release in flight at a time.
2. `git switch main && git pull --ff-only`. Find the current version: `git tag --list 'v*' --sort=-v:refname | head -1`, and check it against `AppInfo.version` in `Sources/AddonKit/Sources/Source.swift`.
3. Work out the new version: the argument if it's `X.Y.Z`, otherwise bump `patch` (the default), `minor` or `major`. Stop if the tag `vX.Y.Z` already exists.
4. `git switch -c release/vX.Y.Z`, then update every version number:
   - `App/project.yml`: `CFBundleShortVersionString: "X.Y.Z"`, and `CFBundleVersion` plus one
   - `App/Reload/Info.plist`: the same two keys (`/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString X.Y.Z' -c 'Set :CFBundleVersion N'`)
   - `Sources/AddonKit/Sources/Source.swift`: `AppInfo.version`
   - Then `rg -n '<old version>' --glob '!build' --glob '!docs/decisions'` and fix any other copy that describes the current version, not history.
5. Commit `bump version to X.Y.Z` and `git push -u origin release/vX.Y.Z`.
6. Open the PR as a draft: `gh pr create --draft --base main --title "Reload X.Y.Z" --body-file <notes>`, with the notes from **Release notes** below (an empty "What's new" list is fine at this point).
7. Reply with the PR link and the version.

## While the release is open

- Work lands on `release/vX.Y.Z`: commit there directly, or merge feature branches into it. Not into `main`.
- After a change a player would notice, run `/release notes`.

## Notes

1. Switch to the open `release/vX.Y.Z` branch and `git pull --ff-only`.
2. Write the notes (see **Release notes**), comparing against the last published release.
3. `gh pr edit <number> --body-file <notes>`. Reply with one line saying what changed in the notes.

## Publish

Merging the release PR publishes the release by itself: the Release workflow tests and builds the merge commit, tags it `vX.Y.Z`, publishes the release with the PR description as its notes, and deletes the branch. `/release publish` checks that it worked and recovers when it didn't.

1. Find the release PR: `gh pr list --head release/vX.Y.Z --state merged`. Stop if it isn't merged yet; merging is the user's call, so don't merge it yourself unless they ask.
2. Watch its run: `gh run list --workflow release.yml --event pull_request -L 1`, then `gh run watch <id>`.
3. **If it passed:** check that `https://github.com/miotke/reload/releases/latest` redirects to `vX.Y.Z`, the DMG downloads, and `releases/latest/download/appcast.xml` names X.Y.Z. `git switch main && git pull --ff-only && git branch -d release/vX.Y.Z`. Reply with the release link.
4. **If it failed,** report the failing step plainly, then publish from this Mac:
   1. `git switch main && git pull --ff-only`. Check `AppInfo.version` is X.Y.Z and `HEAD` is the PR's merge commit (`gh pr view <number> --json mergeCommit -q .mergeCommit.oid`).
   2. `swift test`, `swift scripts/check-docs.swift` and the app tests (`xcodebuild … test`). Stop on a failure.
   3. If the run didn't get as far as tagging: `git tag -m "Reload X.Y.Z" vX.Y.Z && git push origin vX.Y.Z`. The tag starts a second run that drafts the release; let it, or build here with `scripts/release.sh X.Y.Z`.
   4. Save the notes: `gh pr view <number> --json body -q .body | grep -v '^🤖 Generated with' > build/release/notes-X.Y.Z.md`.
   5. Write the signed update feed: `scripts/appcast.sh X.Y.Z build/release/notes-X.Y.Z.md` (reads the Sparkle key from the login keychain; `docs/app/updates.md`). Every release needs it, or installed copies find no update.
   6. Publish: `gh release edit vX.Y.Z --notes-file build/release/notes-X.Y.Z.md --draft=false --latest` and `gh release upload vX.Y.Z build/release/appcast.xml --clobber` if a draft exists, otherwise `gh release create vX.Y.Z build/release/Reload-X.Y.Z.dmg* build/release/Reload-X.Y.Z.zip* build/release/appcast.xml --verify-tag --latest --title "Reload X.Y.Z" --notes-file build/release/notes-X.Y.Z.md`.
   7. Check `releases/latest` as in step 3, delete the branch (`git push origin --delete release/vX.Y.Z`), and reply with the release link.

## Release notes

Written for players, not developers. Every release gets the same three parts, plus the PR attribution footer from the session's instructions while it's a PR description:

```markdown
Reload is a native macOS add-on manager for World of Warcraft: Forever: search, install, update and roll back add-ons from the app or the `reload` command.

## What's new in X.Y.Z

- Plain-language bullets, newest and biggest first.

## Install

Download `Reload-X.Y.Z.dmg`, open it and drag Reload into Applications. <signing line>. Requires macOS 26 or later on Apple silicon.
```

- **What's new** compares against the last *published* release: `gh release list --exclude-drafts --limit 1 --json tagName -q '.[0].tagName'`, then `git log --oneline vPREV..HEAD`. If nothing has been published yet, say it's the first public release and list the main features from the README instead.
- Group commits by what a player notices (new features, fixes, changes to where data lives). Leave out docs, tests, refactors and release plumbing unless they change behaviour. Never paste raw commit subjects.
- Call out anything a player has to do or will see once, such as a one-time migration or a new permission prompt.
- Signing line: "Unsigned build: the first time, open Reload, then go to System Settings ▸ Privacy & Security and click Open Anyway" when the build is ad-hoc signed, otherwise "Signed and notarized".
