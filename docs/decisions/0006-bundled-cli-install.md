# 0006: Bundle the CLI in the app and install it as a symlink

The app ships `addonctl` at `Contents/Helpers/addonctl` and, once at first launch, offers to link it into `/usr/local/bin` through an admin prompt run by `osascript` off the main thread.

- **Status:** Accepted
- **Date:** 2026-10-11

## Context

Most people start with the app, not with `swift build`. They should get the CLI without a separate download, and it should stay in step with the app's version, because both share the store format.

Writing to `/usr/local/bin` needs admin rights. The first version created the link with `NSAppleScript` on the main thread, which froze the whole UI while the password prompt was up.

## Decision

- The Xcode project builds `addonctl` from `Sources/addonctl` and copies it into `ForeverAddons.app/Contents/Helpers/addonctl`, code-signed with the app.
- At first launch (after the seeding sheet), the app asks once: **Install** or **Not Now**. The answer is remembered (`didOfferCommandLineTool`).
- **Install** creates a **symlink** `/usr/local/bin/addonctl` → the helper, so updating the app updates the tool.
- The link is created with `do shell script … with administrator privileges`, run through **`/usr/bin/osascript` as a subprocess, off the main thread**.
- Settings ▸ Command-Line Tool shows the status and offers Install, Repair (link points to another copy) and Uninstall.
- Uninstall only removes a symlink that points into a `ForeverAddons.app` bundle.

## Alternatives considered

| Option | Why not |
|---|---|
| Copy the binary | Goes stale when the app updates |
| `NSAppleScript` on the main thread | Froze the UI during the prompt (the original bug) |
| `SMAppService` / a privileged helper | Far more machinery for one symlink |
| Install into `~/bin` without a prompt | Not on the default `PATH` |
| Ask on every launch | Nagging |

## Consequences

- One app download gives both front ends at the same version.
- The UI stays responsive during the password prompt.
- In Debug builds the link points into DerivedData.
- The privileged runner is injectable; tests and agents never run the real prompt.

## See also

- [app/cli-install.md](../app/cli-install.md)
- [app/project.md](../app/project.md#embedded-cli)
