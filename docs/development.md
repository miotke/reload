# Development

How to build and test ForeverAddons, how to run it without touching your real setup, and the code and docs conventions.

## Requirements

- macOS 27, Xcode 27 (Swift 6.4)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), only when changing `App/project.yml`

If `xcode-select -p` points to the Command Line Tools, either run `sudo xcode-select -s /Applications/Xcode.app` or put `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in front of each command below.

## Repository layout

```
Package.swift            AddonKit library, addonctl CLI, AddonKitTests, addonctlTests
Sources/AddonKit/        core library (architecture/core.md)
Sources/addonctl/        command-line tool (cli/commands.md)
Tests/AddonKitTests/     Swift Testing suites; Fixtures/ holds recorded GitHub JSON, a catalogue CSV, zips
Tests/addonctlTests/     CLI tests
App/project.yml          XcodeGen spec for the app (app/project.md)
App/ForeverAddons/       SwiftUI app
App/ForeverAddonsTests/  app unit tests
docs/                    all documentation (README.md is the index)
```

## Build and test

| Task | Command |
|---|---|
| Core + CLI tests | `swift test` |
| Live GitHub tests | `ADDONS_LIVE_TESTS=1 swift test` |
| CLI | `swift run addonctl --help` |
| CLI release build | `swift build -c release --product addonctl` |
| App build | `xcodebuild -project App/ForeverAddons.xcodeproj -scheme ForeverAddons -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData build` |
| App tests | the same command with `test` instead of `build` |
| UI snapshots | `scripts/snapshots.sh` ([below](#snapshots)) |
| Regenerate Xcode project | `cd App && xcodegen generate` (commit the result) |

Or open `App/ForeverAddons.xcodeproj` in Xcode, choose the **ForeverAddons** scheme and **My Mac**, and press ⌘R. Targets and the embedded CLI: [app/project.md](app/project.md).

Run the app and the tests before saying something works. Report failures plainly.

## Snapshots

`scripts/snapshots.sh` renders the app's key views to `build/snapshots/<name>-<light|dark>.png` (gitignored), so you can see the UI without launching the app. It runs `SnapshotTests` (`xcodebuild test -only-testing:ForeverAddonsTests/SnapshotTests`).

- **Agents must view the PNGs (the Read tool shows images) after every UI change**, in both modes, and fix clipping, wrong states or poor contrast before saying the change works.
- Covered: Browse rows in each state (installed, update, not installed, Retail-only, Classic-only, not checked), the games bubbles with the status bar's legend and "Last fetched", Installed rows (managed, update, pinned, Retail build, unmanaged and a Questie-like group), the inspector (installed, not installed, Retail-only with **Install Retail Build…**, unmanaged with a suggestion), the Retail build sheet, the adopt sheet and the seeding sheet, plus navigation: the sidebar with counts (also while refreshing), a selected category, the installation menu's items, the Updates, Unmanaged and Pinned sections, and each Settings tab (General, Appearance with the icon grid, GitHub, Command Line, Advanced). The Settings window's frame and tab bar can't be drawn offscreen.
- Data comes from `Fixtures` and a test-only `FixtureManager` (`App/ForeverAddonsTests/Snapshots/`); nothing touches disk or the network, and none of it is in the app target ([decision 0007](decisions/0007-real-data-only.md)).
- Views are drawn in an offscreen `NSHostingView`, not `ImageRenderer`: `ImageRenderer` leaves scroll views blank and draws borderless and link buttons as yellow placeholders. `Table` doesn't render either way, so rows are the real cell views stacked at the column widths.
- Controls draw as in an inactive app, so prominent buttons are grey rather than the accent colour. Menus can't be drawn offscreen, so the installation menu is shown as its item labels in a menu-style panel; sidebar selection is redrawn by the renderer and its text looks slightly dim.
- A test passes when rendering succeeds; nothing is compared against a reference image.

## Testing without touching your real setup

- **Unit tests never touch real folders.** Directories are injected (`AppDirectories(root:)` on a temp folder), HTTP goes through `StubHTTPClient`, and downloads through `StubDownloadTransport`.
- **Manual runs:** set `ADDONS_DATA_DIR=<temp folder>`, which works for both the app and the CLI ([app/project.md](app/project.md#addons_data_dir)). Then add a fake installation such as `<tmp>/World of Warcraft/_classic_beta_/Interface/AddOns`.
- **Never** point tests or manual runs at the real WoW folder or `~/Library/Application Support/com.andrewmiotke.ForeverAddons`.
- **Smoke-test and profiling launches** run in the background, stay brief, and are quit afterwards. Never quit the user's own running copy.
- **No privileged commands.** Don't run the CLI install's admin prompt yourself ([app/cli-install.md](app/cli-install.md)).
- **Reset first-launch state:**
  - CLI offer: `defaults delete com.andrewmiotke.ForeverAddons didOfferCommandLineTool`
  - Seeding sheet: `defaults delete com.andrewmiotke.ForeverAddons didSeedAddonDetails`

### What the tests cover

- Pure code: TOC parsing edge cases (BOM, CRLF, interface lists, colour codes), TOC suffix splitting, `release.json`, `.build.info`, search ranking against a fixture catalogue.
- `ReleaseSelector` against recorded GitHub JSON: no `release.json`, no Forever entry in the newest release, prerelease-only, drafts, `nolib` assets.
- The installer against a temp `AddOns` folder with tiny fixture zips: normal install, an update that drops a folder, conflicts, unmanaged overwrite, zip-slip, and a failure mid-swap that must restore backups.
- One opt-in live test resolves real add-ons against GitHub (`ADDONS_LIVE_TESTS=1`).

## Conventions

- **Language settings:** Swift 6 with strict concurrency; details in [architecture/concurrency.md](architecture/concurrency.md).
- **Shared state:** actors or `Mutex`, not locks or `@unchecked Sendable`.
- **Dependencies:** Apple frameworks only. The only third-party packages are ZIPFoundation and swift-argument-parser. Persistence uses the system SQLite (`import SQLite3`).
- **Tests:** Swift Testing (`@Test`, `#expect`), not XCTest.
- **Real data only:** no mock managers or sample data in the app target ([decision 0007](decisions/0007-real-data-only.md)).
- **Xcode project:** edit `App/project.yml`, never `project.pbxproj` by hand.
- **Style:** match the surrounding file. Comments explain *why*, not *what*.
- **Before touching requests or hot paths:** read [network/overview.md](network/overview.md) and [performance/guidelines.md](performance/guidelines.md).

## Docs

- One topic per file, about 40–150 lines, in the folders listed in [README.md](README.md). Every new file gets a line there.
- Update the relevant doc in the same commit as the code change.
- Run `swift scripts/check-docs.swift` before committing. It verifies links, the index, file sizes, doc paths in comments, and the "Where things live" tables.
- After merging app changes into `main`, add [decision records](decisions/README.md) and update the numbers in [network/budget.md](network/budget.md) and [performance/measurements.md](performance/measurements.md).
- No READMEs in subfolders except `decisions/README.md`, the decision index.
