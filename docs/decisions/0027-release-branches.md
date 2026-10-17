# 0027: Release branches

Each version gets a `release/vX.Y.Z` branch. Every change for that version lands there, its pull request into `main` carries the release notes, and merging it is the release.

- **Status:** Accepted
- **Date:** 2026-10-12

## Context

Reload 0.1.2 was the first published release. Until then work went straight onto `main`, and a release was a separate version-bump PR whose notes were written at the end. With real users, `main` should only move when a version ships, and the notes should build up while the work happens instead of being reconstructed from the log.

## Decision

- **One branch per version, `release/vX.Y.Z`**, opened by `/release start` with the version bump as its first commit. One release is in flight at a time.
- **All work for the version lands on that branch**, as direct commits or merged feature branches. `main` only takes release merges.
- **The PR description is the release notes**, written for players and refreshed with `/release notes` as changes land.
- **Merging is the release.** A workflow on the merge's push to `main` tests and builds the merge commit, tags it `vX.Y.Z` and publishes the release with the PR description as its notes. Merging is the owner's approval, so the release is published directly rather than left as a draft. `/release publish` checks the run and finishes by hand if it failed.
- **`main` is protected by a ruleset:** no force pushes or deletion, and a PR is required for everyone except the repository admin.
- Details: [app/releases.md](../app/releases.md).

## Alternatives considered

| Option | Why not |
|---|---|
| Branch named `vX.Y.Z` | A branch and a tag with the same name make git refs ambiguous |
| Keep working on `main`, cut releases from tags | `main` would carry unreleased work, and the notes would still be written at the end |
| Leave each release as a draft for a second check | The merge already is that check |

## Consequences

- Anything that should reach users waits for the next release merge, including docs fixes shown on the GitHub landing page.
- Releasing needs no Mac once the PR merges. It depends on CI building with Xcode 26 ([decision 0028](0028-macos-26-minimum.md)); if a run fails, the tag can still be pushed by hand.
- Tags made by the workflow aren't GPG-signed.
- Decision records and measurement updates are written when changes merge into the release branch.
