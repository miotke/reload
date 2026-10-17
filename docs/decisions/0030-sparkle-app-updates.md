# 0030: Sparkle for Reload's own updates

Reload updates itself with Sparkle 2, from an EdDSA-signed feed published as a release asset, without a paid Apple Developer ID.

- **Status:** Accepted
- **Date:** 2026-10-17

## Context

Players downloaded every new version by hand. Releases are ad-hoc signed ([decision 0025](0025-github-releases-with-optional-signing.md)), so every download is quarantined and needs **Open Anyway** in Privacy & Security, every time. Reload was about to be shared with the WoW Forever community, where most players won't follow release pages.

The project took no third-party dependencies beyond ZIPFoundation and swift-argument-parser.

## Decision

- **Sparkle 2.10.0**, pinned, in the app target only. Its update window, release notes and install-and-relaunch replace building our own. This is the third dependency, and the rule in `.claude/CLAUDE.md` now names it.
- **Release builds only**: Debug builds and the UI tests have no updater.
- **Feed as a release asset**: `appcast.xml` on every release, read through `releases/latest/download/appcast.xml`, GitHub's quota-free redirect. No commits to `main` from CI, no hosting.
- **Everything signed with one Ed25519 key**: the zip (`edSignature`) and the feed (`SURequireSignedFeed`, which needs `SUVerifyUpdateBeforeExtraction`). The key is in the maintainer's keychain and the `SPARKLE_ED_PRIVATE_KEY` secret. Publishing fails before tagging without it.
- **Notes from the release PR**: its "What's new" section, as Markdown.
- **`disable-library-validation` entitlement**: needed for an ad-hoc app with the hardened runtime to load the embedded framework at all.

## Alternatives considered

| Option | Why not |
|---|---|
| Our own updater (download, check the `.sha256`, swap, relaunch) | Days of security-sensitive work: verifying, replacing a running app, relaunching. Sparkle has done this for years |
| A `curl \| bash` install script | Avoids quarantine for installs, but players still update by hand; it's a possible extra, not a replacement |
| Homebrew cask | Homebrew is dropping unsigned casks |
| Feed committed to `main` or on GitHub Pages | The release workflow can't push to `main` (ruleset), and Pages is one more thing to host |
| Developer ID signing and notarization | $99 a year. Still possible later: the workflow already supports it, and Sparkle keeps working |
| Turning the hardened runtime off for ad-hoc builds | Weakens every build to work around a signing detail; the entitlement is narrower |
| No signed feed | The notes and download URL could be swapped by anyone who can alter the response |

## Consequences

- Updates after 0.1.7 install from inside the app, with no Gatekeeper prompt. Getting 0.1.7 itself is still a manual download.
- Losing the private key strands installed copies: they accept no other key.
- The Keychain prompt for the GitHub token still returns after updates, because each ad-hoc build is a new signer. A stable self-signed certificate would fix that separately.
- One more request a day, to github.com's redirect and the release-assets host, outside the add-on request budget ([network/budget.md](../network/budget.md#reloads-own-updates)). It isn't shown in Window ▸ Network Activity, which records the core's requests.
- Details: [app/updates.md](../app/updates.md).
