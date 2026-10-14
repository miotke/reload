# Releases

How a version of Reload gets built and published on GitHub Releases. There's no Mac App Store build ([decision 0025](../decisions/0025-github-releases-with-optional-signing.md)).

## Cutting a release

Each version has a release branch, and merging it is the release ([decision 0027](../decisions/0027-release-branches.md)).

```
main ──●──────────────────────●  merge commit = vX.Y.Z: tagged, built, published
        \                    /
release/vX.Y.Z  ●──●──●──●──●    version bump first, then every change for the release
                PR description = the release notes
```

1. **Start:** branch `release/vX.Y.Z` off `main`, bump the version in all three places (`CFBundleShortVersionString` in `App/project.yml` and `App/Reload/Info.plist`, `AppInfo.version` in `Sources/AddonKit/Sources/Source.swift`; the release script refuses to build when they differ from the tag), push, and open a draft PR into `main` titled "Reload X.Y.Z".
2. **Work:** every change for the version lands on that branch. The PR description holds the player-facing notes: what Reload is, what's new since the last published release, how to install. Keep it current as changes land.
3. **Merge** the PR when the version is ready. Only the owner merges into `main` (a ruleset requires a PR for everyone else).
4. **Publish (automatic):** the merge starts the **Release** workflow (`.github/workflows/release.yml`). It checks out the merge commit and runs the same checks as every push (docs check, `swift test`, app tests, timing budgets ×3); **if any fails, nothing is built, tagged or published**. Then it builds with `scripts/release.sh`, then tags the commit `vX.Y.Z` and publishes the release with `Reload-<version>.dmg`, `Reload-<version>.zip`, a `.sha256` for each, and the PR description as the notes (minus the Claude Code attribution line). Last, it deletes the release branch. It only does this for a merged PR from a `release/v*` branch in this repo. The tag is created only after the build succeeds; it's annotated but not GPG-signed, because the workflow has no signing key.
5. **If the run fails,** nothing is tagged or published. Fix the problem, or push the tag by hand: a pushed `v*` tag starts the workflow again in its older mode, which drafts the release with generated notes for you to edit and publish. `/release publish` does this.

In Claude Code, `/release start` and `/release notes` do steps 1–2, and `/release publish` checks step 4 and handles step 5 (`.claude/skills/release/SKILL.md`). The branch is `release/vX.Y.Z`, not `vX.Y.Z`, because a branch and a tag with the same name make git refs ambiguous.

To try a build without releasing, run the workflow by hand (Actions ▸ Release ▸ Run workflow) with a version. The files are kept as a workflow artifact instead.

## Building locally

```sh
scripts/release.sh 0.2.0
```

Output goes to `build/release/` (gitignored): `Reload.app`, `Reload-0.2.0.dmg`, `Reload-0.2.0.zip` and their `.sha256` files. The app bundles the `reload` CLI in `Contents/Helpers` ([cli-install.md](cli-install.md)), so each download ships both. The build is arm64 only (`ARCHS: arm64` in `project.yml`): Reload supports Apple silicon only ([decision 0028](../decisions/0028-macos-26-minimum.md)).

## The disk image

The DMG opens a Finder window with Reload on the left, Applications on the right and a gold arrow between them, over the background `App/Design/render-dmg-background.swift` draws (`dmg-background.tiff`, 1x and 2x). `scripts/dmg-settings.py` sets the window size and icon positions; the two files share the coordinates and must change together.

It's built by [dmgbuild](https://pypi.org/project/dmgbuild/), pinned in `release.sh` and installed into `build/dmgbuild-venv` on first use. dmgbuild writes the window layout (`.DS_Store`) itself, so the build never scripts Finder and works headless in CI. The zip stays alongside for scripts and a future Homebrew cask.

## Signing and notarization

Off until set up. Without them the build is ad-hoc signed, and people opening it on another Mac must allow it once: open it, then click **Open Anyway** in System Settings ▸ Privacy & Security. macOS no longer offers right-click ▸ Open as a bypass.

| Variable (local) | GitHub secret | What it is |
|---|---|---|
| `RELOAD_TEAM_ID` | `TEAM_ID` | Apple team ID; switches signing to the "Developer ID Application" certificate |
| — | `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD` | the certificate exported from Keychain Access as .p12, base64-encoded (`base64 -i cert.p12 \| pbcopy`) |
| `RELOAD_NOTARY_PROFILE` | — | a profile saved with `xcrun notarytool store-credentials` (easiest locally) |
| `RELOAD_NOTARY_KEY_PATH`, `_KEY_ID`, `_ISSUER_ID` | `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | an App Store Connect API key (Users and Access ▸ Integrations), the .p8 file's contents as the secret |
| `RELOAD_KEYCHAIN` | set by the workflow | keychain holding the certificate; CI makes a temporary one and deletes it afterwards |

With a team ID the script signs with a secure timestamp and the hardened runtime (already on in `project.yml`). With notary credentials too, it submits the app, waits, staples the ticket and checks it with `spctl` before zipping. The DMG is then signed and notarized on its own. Notarization without a Developer ID signature is an error.

## CI runner

The workflow runs on `macos-26` and picks the newest `/Applications/Xcode_26*.app` or later, since the project needs Swift 6.2 and the macOS 26 SDK. If the runner has none, the job fails with the list of installed versions.

## Not done yet

- **Auto-update.** Users download new versions by hand. Sparkle is the usual choice outside the App Store.
- **Homebrew cask.** It would let people `brew install --cask reload`, pointing at the zip.
