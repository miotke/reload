# Releases

How a version of Reload gets built and published on GitHub Releases. There's no Mac App Store build ([decision 0025](../decisions/0025-github-releases-with-optional-signing.md)).

## Cutting a release

1. Bump the version in all three places: `CFBundleShortVersionString` in `App/project.yml` and `App/Reload/Info.plist`, and `AppInfo.version` in `Sources/AddonKit/Sources/Source.swift`. The release script refuses to build when they differ from the tag.
2. Commit, then tag and push: `git tag v0.2.0 && git push origin v0.2.0`.
3. The **Release** workflow (`.github/workflows/release.yml`) runs `swift test`, builds with `scripts/release.sh` and creates a **draft** release with `Reload-<version>.zip` and its `.sha256`.
4. Check the draft on GitHub, edit the notes, publish.

To try a build without releasing, run the workflow by hand (Actions ▸ Release ▸ Run workflow) with a version. The zip is kept as a workflow artifact instead.

## Building locally

```sh
scripts/release.sh 0.2.0
```

Output goes to `build/release/` (gitignored): `Reload.app`, `Reload-0.2.0.zip`, `Reload-0.2.0.zip.sha256`. The app bundles the `reload` CLI in `Contents/Helpers` ([cli-install.md](cli-install.md)), so one zip ships both. macOS 27 runs only on Apple silicon, so the build is arm64 only.

## Signing and notarization

Off until set up. Without them the build is ad-hoc signed, and people opening it on another Mac must right-click ▸ Open (or allow it in System Settings ▸ Privacy & Security) the first time.

| Variable (local) | GitHub secret | What it is |
|---|---|---|
| `RELOAD_TEAM_ID` | `TEAM_ID` | Apple team ID; switches signing to the "Developer ID Application" certificate |
| — | `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD` | the certificate exported from Keychain Access as .p12, base64-encoded (`base64 -i cert.p12 \| pbcopy`) |
| `RELOAD_NOTARY_PROFILE` | — | a profile saved with `xcrun notarytool store-credentials` (easiest locally) |
| `RELOAD_NOTARY_KEY_PATH`, `_KEY_ID`, `_ISSUER_ID` | `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | an App Store Connect API key (Users and Access ▸ Integrations), the .p8 file's contents as the secret |
| `RELOAD_KEYCHAIN` | set by the workflow | keychain holding the certificate; CI makes a temporary one and deletes it afterwards |

With a team ID the script signs with a secure timestamp and the hardened runtime (already on in `project.yml`). With notary credentials too, it submits the app, waits, staples the ticket and checks it with `spctl` before zipping. Notarization without a Developer ID signature is an error.

## CI runner

The workflow runs on `macos-latest` and picks the newest `/Applications/Xcode_27*.app`, since the deployment target needs the macOS 27 SDK. If the runner has no Xcode 27 yet, the job fails with the list of installed versions; change `runs-on` to a newer image when GitHub adds one.

## Not done yet

- **Auto-update.** Users download new versions by hand. Sparkle is the usual choice outside the App Store.
- **DMG and Homebrew cask.** A zip is enough for now; a cask would let people `brew install --cask reload`.
