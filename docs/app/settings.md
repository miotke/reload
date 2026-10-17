# Settings window

The Settings window's tabs, what each stores and where, and how the alternate app icon works (and why Finder never shows it).

Code: `App/Reload/Views/SettingsView.swift` (scene root, General and Advanced), `Views/AppearanceSettings.swift`, `Views/SourcesSettings.swift`, `Views/GitHubSettings.swift`, `Models/GitHubStatusModel.swift`, `Views/CommandLineToolViews.swift`, `Support/SettingsSupport.swift`. Why: [decision 0022](../decisions/0022-mac-style-settings-and-alternate-icons.md).

## Layout

- The `Settings` scene holds a `TabView`, which macOS draws as the standard preferences window: icon-and-label toolbar tabs, the title following the tab.
- Each tab is a `Form` with `.formStyle(.grouped)`, 520 pt wide and as tall as its content (`settingsTab()`), so the window resizes per tab with no empty space.
- The selected tab is remembered under `settingsTab`.
- Only `SettingsView` reads `AppModel` from the environment ([decision 0015](../decisions/0015-environment-only-at-scene-roots.md)); each tab gets plain properties, so snapshots render them without the app.

| Tab | Symbol | Contents |
|---|---|---|
| General | `gearshape` | default channel, check for updates automatically, default installation (only with more than one), [dependencies](#dependencies), show add-ons for other games, update count in the menu bar |
| Appearance | `paintpalette` | Light / Dark / System cards, app icon grid |
| Sources | `shippingbox` | a switch per source (GitHub, WoWInterface, Tukui) for search and Browse ([sources.md](../features/sources.md)) |
| GitHub | `person.badge.key` | token field with Save and Remove, which token is in use, rate limits, links about tokens |
| Command Line | `terminal` | `reload` status with Install / Repair / Uninstall ([cli-install.md](cli-install.md)), example commands |
| Advanced | `gearshape.2` | show the data and caches folders in Finder, reset first-launch steps |

## Keys

All in the app's user defaults (`SettingsKey`), except the token and the sources.

| Setting | Key / storage |
|---|---|
| Default channel | `defaultChannel` |
| Check for updates automatically | `checkForUpdatesOnLaunch` |
| Default installation | `selectedInstallation` (the same one the title menu picks) |
| When an add-on needs another add-on | `dependencyPolicy` (`DependencyPolicy` raw value: `ask`, `install`, `warn`; `ask` when unset) |
| Warn before removing an add-on others need | `warnBeforeRemovingDependencies` (on when unset) |
| Show add-ons for other games | `browseShowOtherGames` (off when unset; Browse then hides what won't load, [search.md](../features/search.md#in-the-app)) |
| Show update count in the menu bar | `showMenuBarExtra` |
| Appearance | `appearance` (`AppAppearance`, also View ▸ Appearance) |
| App icon | `appIcon` (`AppIconChoice`) |
| Selected tab | `settingsTab` |
| GitHub token | Keychain, never in the JSON store |
| Sources | `source_settings` in the metadata database, shared with `reload sources`; `AppModel.sources` re-reads it on launch, when the tab opens and on activation after another process wrote |

## Dependencies

General's **Dependencies** section, between Installation and Menu Bar:

- **When an add-on needs another add-on**: Ask to install it (default) · Install it automatically · Only show a warning. Read when an install finishes (`DependencyPolicy.stored()`).
- **Warn before removing an add-on others need** (on): the uninstall confirmation names the add-ons that stop loading.
- A footnote says Installed shows what's missing either way, and that only an add-on the core is sure of is installed.

What each does: [required-addons.md](required-addons.md).

## GitHub

- "Token in use" follows the core's order: `RELOAD_GITHUB_TOKEN`, then `GITHUB_TOKEN`, then the Keychain (`GitHubTokenSource`). When a variable is set, a footnote says the Keychain token is ignored.
- Save and Remove write the Keychain, then call `tokenDidChange()` on the manager.
- Save and Remove also reload the rate limits, since the token changes them.

### Rate limits

From `AddonManaging.gitHubStatus()`, which reads stored state only (no requests). `GitHubStatusModel` decides when to ask; `GitHubStatusDisplay` formats.

| Row | Shows |
|---|---|
| Warning (only while `webPausedUntil` is ahead) | "github.com asked us to slow down — resumes in 4 min." |
| API requests | "42 of 60 left" (5,000 with a token, or the core's `apiLimit`), a capacity gauge, "Resets in 23 min" |
| Searches | the same against 10 a minute (30 with a token) |

- Unknown values read "Not used yet" with the hourly or per-minute limit, so the empty default (before the core reports anything) looks deliberate.
- A reset time in the past shows a full window: GitHub has refilled it since it last reported.
- Used up turns the row orange: "Used up, resets in …".
- Times round up ("under a minute", "23 min", "1 hr 5 min") and are measured from when the status was read.
- Loaded by the tab's `.task`: on appear, every 30 s while visible, and after the app's own metadata writes (at most every 2 s). Leaving the tab cancels it.
- A footnote says browsing and update checks mostly use quota-free requests ([budget.md](../network/budget.md)).

## Advanced

- **Show in Finder** opens `AppEnvironment.directories()`: Application Support and Caches, or the folders under `RELOAD_DATA_DIR`. A missing folder is created first.
- **Reset…** asks for confirmation, then sets `didSeedAddonDetails` to false and clears `didOfferCommandLineTool` (`FirstLaunchSteps`). The seeding sheet comes back on the next launch even though refreshes have run, and so does the `reload` offer unless the command is already installed ([first-launch.md](first-launch.md)).
- With `RELOAD_DATA_DIR` those steps aren't remembered, so the button is disabled.

## App icon

Four choices, `AppIconChoice`, each an imageset in `Assets.xcassets`:

| Choice | Asset |
|---|---|
| Classic (default) | `AltIcon-Classic` |
| Rune | `AltIcon-Rune` |
| Scroll | `AltIcon-Scroll` |
| Gilded | `AltIcon-Gilded` |

- At launch (the main window's `onChange(initial:)`) and on every change (also from the Settings root), `apply()` sets `NSApp.applicationIconImage`.
- Classic sets `nil`, so the bundle's `AppIcon` is used. A choice whose artwork is missing also sets `nil` rather than a blank tile.
- The grid loads artwork with `NSImage(named:)` and draws a labelled rounded square when it's missing (as in the test bundle, which has no asset catalog).

### Finder limitation

`applicationIconImage` changes the **Dock and app switcher** only, and only while the app runs. Finder, Launchpad and Spotlight read the bundle's icon. The picker's footnote says so.

Changing that would mean writing into the bundle or calling `NSWorkspace.setIcon(_:forFile:)`, which adds a resource fork and breaks the code signature (the app is signed "Sign to Run Locally"). macOS has no supported alternate-icon API for Mac apps.

## Snapshots

`settings-general`, `settings-appearance` (icon placeholders), `settings-sources`, `settings-github`, `settings-github-environment`, `settings-command-line` and `settings-advanced`, light and dark ([development.md](../development.md#snapshots)). The window chrome and tab bar aren't drawn offscreen.
