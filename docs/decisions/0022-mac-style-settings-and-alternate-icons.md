# 0022: Mac-style tabbed Settings; alternate icons through `applicationIconImage` only

Settings became a standard toolbar-tab preferences window of grouped forms, and the new app icon picker changes only the running app's Dock and app switcher icon.

- **Status:** Accepted
- **Date:** 2026-10-12

## Context

- Settings was one long grouped `Form`: GitHub token, updates, appearance, menu bar and the CLI section, stacked in a 480 pt column. It grew with every feature and didn't look like other Mac apps' settings.
- The appearance choice was a popup, unlike System Settings ▸ Appearance's thumbnails.
- We wanted a choice of app icons. iOS has `setAlternateIconName`; macOS has no equivalent for apps.
- The app is signed "Sign to Run Locally" with hardened runtime. Anything that writes into the bundle after signing invalidates the signature.
- Settings views must stay renderable in snapshots without the app, and only scene roots may read `AppModel` from the environment ([0015](0015-environment-only-at-scene-roots.md)).

## Decision

- **A `TabView` in the `Settings` scene**: General, Appearance, GitHub, Command Line and Advanced, each with an SF Symbol. macOS draws this as the native preferences window: toolbar tabs, title following the tab, window resizing per tab. The selected tab is stored (`settingsTab`).
- **Each tab is a grouped `Form` sized to its content**: `settingsTab()` applies `.formStyle(.grouped)`, a fixed width and `fixedSize(vertical:)`, with scrolling off, so no tab leaves empty space or clips.
- **Native controls only.** The appearance cards and icon grid are plain buttons drawing thumbnails, with an accent selection ring, like System Settings.
- **`SettingsView` is the only reader of `AppModel`.** Tabs take values, bindings, closures or their own small models (`GitHubTokenModel`, `CommandLineToolModel`), so snapshots build them from fixtures and never touch the Keychain.
- **Alternate icons set `NSApp.applicationIconImage`** from an `AltIcon-*` imageset, at launch and on change; Classic sets `nil` to use the bundle icon. This changes the Dock and app switcher while the app runs. A footnote says Finder always shows the standard icon.
- **The token source is shown, the rate limit isn't.** The app mirrors the core's documented order (environment, then Keychain) for display. Stored rate-limit state isn't on `AddonManaging`, so showing it waits for a core task.
- **Reset first-launch steps** clears the two flags behind a confirmation, and is disabled on `ADDONS_DATA_DIR`, where they aren't stored.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep one long form, add sections | Already long; no native look; one window size for all content |
| A sidebar `NavigationSplitView` like System Settings | Meant for dozens of panes; five tabs fit the toolbar style most Mac apps use |
| `NSWorkspace.setIcon(_:forFile:)` on the app bundle | Writes an `Icon\r` file and Finder info into the bundle, breaking the code signature; needs write access to `/Applications` |
| Copy the chosen icon into `Contents/Resources` and re-sign | Same signature problem, and an app must not modify its own bundle |
| A Dock tile plug-in (`NSDockTilePlugIn`) | Only draws while the Dock loads it, still not Finder, and needs a separate signed bundle for little gain |
| Read the rate limit from the database in the app | Breaks the core/UI boundary ([0020](0020-core-ui-boundary-and-feature-models.md)) |

## Consequences

- Settings looks and behaves like other Mac apps; each tab can grow on its own.
- The Dock icon reverts to the bundle icon whenever the app isn't running, and Finder, Launchpad and Spotlight always show it. This is documented in the picker and in [settings.md](../app/settings.md).
- The icon artwork lives in the asset catalog; until it's there, the grid shows labelled placeholders and `apply()` keeps the bundle icon.
- Showing the rate limit needs a core method (for example a stored `RateLimitState` on `AddonManaging`).
- Snapshots cover every tab's content in both modes; the window chrome and tab bar can't be drawn offscreen, so per-tab window sizing is checked in the running app.
