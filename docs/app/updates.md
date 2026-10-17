# Reload's own updates (Sparkle)

How Reload updates itself: the Sparkle updater in the app, the signed feed each release publishes, and the signing key. Add-on updates are a different thing ([features/refresh.md](../features/refresh.md)). Why Sparkle: [decision 0030](../decisions/0030-sparkle-app-updates.md).

Code: `App/Reload/Support/SparkleUpdater.swift` (starts Sparkle, the test-feed override), `App/Reload/Support/AppUpdater.swift` (what the menu and Settings show), `scripts/appcast.sh`, `scripts/sparkle-tools.sh`.

## In the app

- **Release builds only.** `SparkleUpdater.make()` returns nil in Debug, so a development copy (and the UI tests) never replaces itself with a published release, and the menu item and Settings section are hidden.
- **Reload ▸ Check for Reload Updates…** opens Sparkle's window: "up to date", or the new version with its notes and **Install Update**. "Reload" is in the title because Add-ons ▸ Check for Updates (⌘R) checks add-ons.
- **Settings ▸ General ▸ Reload:** *Check for Reload updates automatically* (on) and **Check Now**. Sparkle stores the switch itself (`SUEnableAutomaticChecks` in user defaults); the Info.plist default is on, so Sparkle never asks on the second launch.
- Sparkle checks once a day (its default) and shows the update window when there's something new. Installing replaces the app at its current path and relaunches it. Sparkle strips the quarantine flag from what it installs, so an update never needs **Open Anyway**.
- The CLI is inside the app bundle, so it updates with it.
- Sparkle stays out of the views: `AppUpdater` is a plain `@Observable` with closures, so Settings and the snapshot tests use it without linking Sparkle. `SparkleUpdater.swift` is excluded from the unit-test bundle.

## The feed

| Info.plist key | Value |
|---|---|
| `SUFeedURL` | `https://github.com/miotke/reload/releases/latest/download/appcast.xml` |
| `SUPublicEDKey` | the public half of the [signing key](#signing-key) |
| `SURequireSignedFeed` | true: the feed itself is signed, so its notes and URLs can't be swapped |
| `SUVerifyUpdateBeforeExtraction` | true: required by Sparkle with a signed feed; the zip is checked before it's unzipped |
| `SUEnableAutomaticChecks` | true |

- The feed is a **release asset**, `appcast.xml`, on every release. `releases/latest/download/…` is GitHub's quota-free redirect to the latest published release, so nothing is committed to `main` and there's no Pages site. A draft or a pre-release is never "latest".
- It has one item, the release itself: `sparkle:version` is `CFBundleVersion` (what Sparkle compares), `shortVersionString` the version, `minimumSystemVersion` the app's `LSMinimumSystemVersion`, and the zip's URL with its EdDSA signature.
- The notes are the release PR's **What's new** section, as Markdown (`sparkle:format="markdown"`); Sparkle renders it in the update window.
- `scripts/appcast.sh <version> [notes.md]` writes `build/release/appcast.xml` after `scripts/release.sh`, then signs the zip and the feed with `sign_update`. `scripts/sparkle-tools.sh` downloads Sparkle's tools into `build/` once, checked against a pinned SHA-256. Keep its `SPARKLE_VERSION` in step with the package in `App/project.yml`.
- **Publishing** (`scripts/ci/publish-release.sh`) writes the feed before tagging and uploads it with the DMG and zip. Without the key secret the run fails there, before anything is tagged: a release without a feed would leave every installed copy finding nothing. A hand-pushed tag's draft gets a feed without notes when the key exists.

## Signing key

- An Ed25519 key pair from Sparkle's `generate_keys --account io.github.miotke.Reload`. The private key lives in the maintainer's login keychain under that account (the backup), and in the repository secret **`SPARKLE_ED_PRIVATE_KEY`** for CI (`generate_keys --account io.github.miotke.Reload -x key.txt`, paste, delete the file).
- Locally, `appcast.sh` reads it from the keychain; macOS asks once to let `sign_update` use it.
- **Losing the key strands every installed copy:** they reject updates signed with any other key. Rotating needs one release signed with the old key that ships the new public key.
- The key signs updates, not the app. The app is still ad-hoc signed unless Developer ID signing is set up ([releases.md](releases.md#signing-and-notarization)).

## Ad-hoc signing and library validation

The hardened runtime's library validation only loads frameworks from the app's own team, and ad-hoc signatures have no team, so an ad-hoc Reload refuses its embedded `Sparkle.framework` and doesn't launch. `App/Reload/Reload.entitlements` sets `com.apple.security.cs.disable-library-validation`. With Developer ID signing the app and framework share a team, and the entitlement could go.

## Testing an update

`RELOAD_UPDATE_FEED=<url>` makes a Release build read another feed (`SparkleUpdater.feedURLString`). It must still be signed with the release key, so it can't install anything the real feed couldn't. To try a full update: build with `scripts/release.sh`, copy the app aside, bump the copy in `build/release` (`CFBundleVersion` too), re-sign it ad hoc with `--preserve-metadata=entitlements`, zip it, run `APPCAST_DOWNLOAD_URL=http://127.0.0.1:8765/Reload-X.Y.Z.zip scripts/appcast.sh X.Y.Z notes.md`, serve the folder with `python3 -m http.server 8765 --bind 127.0.0.1`, and launch the older copy with `RELOAD_DATA_DIR` and `RELOAD_UPDATE_FEED`. Afterwards delete the `SU*` keys the test wrote to `io.github.miotke.Reload`'s defaults.
