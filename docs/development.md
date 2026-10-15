# Development

How to build and test Reload, how to run it without touching your real setup, and the code and docs conventions.

## Requirements

- macOS 26 or later, Xcode 26 or later (Swift 6.2)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), only when changing `App/project.yml`

If `xcode-select -p` points to the Command Line Tools, either run `sudo xcode-select -s /Applications/Xcode.app` or put `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in front of each command below.

## Repository layout

```
Package.swift            AddonKit library, reload CLI, AddonKitTests, reloadTests
Sources/AddonKit/        core library (architecture/core.md)
Sources/reload/        command-line tool (cli/commands.md)
Tests/AddonKitTests/     Swift Testing suites; Fixtures/ holds made-up GitHub JSON, a catalogue CSV, zips
Tests/reloadTests/     CLI tests
App/project.yml          XcodeGen spec for the app (app/project.md)
App/Reload/       SwiftUI app
App/ReloadTests/  app unit tests
docs/                    all documentation (README.md is the index)
scripts/                 release build, snapshots, the docs check
scripts/ci/              the steps the GitHub workflows run (below)
.github/workflows/       tests.yml (every push), release.yml (merging a release PR)
```

## Build and test

| Task | Command |
|---|---|
| Core + CLI tests | `swift test` |
| Live GitHub tests | `RELOAD_LIVE_TESTS=1 swift test` |
| CLI | `swift run reload --help` |
| CLI release build | `swift build -c release --product reload` |
| App build | `xcodebuild -project App/Reload.xcodeproj -scheme Reload -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData build` |
| App tests | the same command with `test` instead of `build` |
| UI snapshots | `scripts/snapshots.sh` ([below](#snapshots)) |
| UI tests (leaks, memory) | `scripts/ui-tests.sh` ([below](#ui-tests)); quit Reload first |
| Regenerate Xcode project | `cd App && xcodegen generate` (commit the result) |
| Release build | `scripts/release.sh <version>` ([app/releases.md](app/releases.md)) |

Or open `App/Reload.xcodeproj` in Xcode, choose the **Reload** scheme and **My Mac**, and press ⌘R. Targets and the embedded CLI: [app/project.md](app/project.md).

Run the app and the tests before saying something works. Report failures plainly.

### Continuous integration

`.github/workflows/tests.yml` runs on every push to any branch, on `macos-26` with the newest Xcode 26 or later, but only what the push needs. A `changes` job on Linux diffs the push (a new branch: since it left `main`):

| Changed | Docs check | `swift test` and app tests |
|---|---|---|
| `Sources/`, `Tests/`, `App/`, `Package.swift`/`.resolved`, `tests.yml` | yes | yes |
| only `docs/`, `README.md`, `.claude/CLAUDE.md`, `scripts/check-docs.swift` | yes | no |
| anything else | no | no |

The workflows stay short: each step calls a script in `scripts/ci/` (`changed-areas.sh`, `select-xcode.sh`, `test.sh docs|core|app`, and the release steps), so a step can be run or read on its own. `scripts/ci/test.sh` runs locally too. Changing `scripts/ci/` counts as a code change, so it's tested in full.

The docs check runs with code changes because it checks code too (the "Where things live" tables, doc paths in comments). A manual run, or a push it can't diff, runs everything. CI sets `RELOAD_PERF_SLACK=3`, which triples the performance tests' timing budgets (`budget(_:)`): shared runners are slower, and the budgets catch O(n²) work, not a slow machine. A newer push to the same branch cancels a run still going. The release workflow runs all of them again on the merge commit and stops before building if any fail ([app/releases.md](app/releases.md)).

The **require tests** ruleset makes the `test` job a required check for merging into `main`, with no bypass: a release PR can't merge until its branch's latest run passes. When nothing needed testing, `test` is skipped, which GitHub counts as passed. Don't move the filter into `on: push: paths:`: a workflow that doesn't run never reports, and the check would block the merge.

## Snapshots

`scripts/snapshots.sh` renders the app's key views to `build/snapshots/<name>-<light|dark>.png` (gitignored), so you can see the UI without launching the app. It runs `SnapshotTests` (`xcodebuild test -only-testing:ReloadTests/SnapshotTests`).

- **Agents must view the PNGs (the Read tool shows images) after every UI change**, in both modes, and fix clipping, wrong states or poor contrast before saying the change works.
- Covered: Browse rows in each state (installed, update, not installed, Retail-only, Classic-only, not checked), the games bubbles with the status bar's legend and "Last fetched", Installed rows (managed, update, pinned, Retail build, unmanaged and a Questie-like group), the inspector (installed, not installed, Retail-only with **Install Retail Build…**, unmanaged with a suggestion), the Retail build sheet, the adopt sheet and the seeding sheet, plus navigation: the sidebar with counts (also while refreshing), a selected category, the installation menu's items, the Updates, Unmanaged and Pinned sections, and each Settings tab (General, Appearance with the icon grid, GitHub, Command Line, Advanced). The Settings window's frame and tab bar can't be drawn offscreen.
- Data comes from `Fixtures` and a test-only `FixtureManager` (`App/ReloadTests/Snapshots/`); nothing touches disk or the network, and none of it is in the app target ([decision 0007](decisions/0007-real-data-only.md)).
- Views are drawn in an offscreen `NSHostingView`, not `ImageRenderer`: `ImageRenderer` leaves scroll views blank and draws borderless and link buttons as yellow placeholders. `Table` doesn't render either way, so rows are the real cell views stacked at the column widths.
- Controls draw as in an inactive app, so prominent buttons are grey rather than the accent colour. Menus can't be drawn offscreen, so the installation menu is shown as its item labels in a menu-style panel; sidebar selection is redrawn by the renderer and its text looks slightly dim.
- A test passes when rendering succeeds; nothing is compared against a reference image.

## UI tests

`App/ReloadUITests` drives the real app and fails on leaks or memory growth. **Not in CI**: GitHub's runners have no unlocked desktop to drive. It runs on this Mac **before each push**.

- `MemoryUITests` launches a throwaway Reload over `UITestFixture`: a temp `RELOAD_DATA_DIR` with a fake installation and 600 WoWInterface catalogue rows, marked refreshed and downloaded, so there's no first-launch sheet and no network. It then repeats, 1 warm-up round plus 8: Browse search, scrolling, the inspector, an add-on window, Window ▸ Network Activity, Settings ▸ Sources (WoWInterface off and on), Installed.
- After the warm-up and after the rounds, `scripts/ui-tests.sh` measures the app from outside (the test runner is sandboxed and can't): `leaks`, `heap` (live bytes) and `footprint`, plus the footprint after every round as a trend. It fails if leaked bytes grow by more than 16 KB or the live heap by more than 4 MB. The footprint is printed but not judged: it counts freed memory the allocator keeps and swings by tens of MB on its own. Apple's constant ~20 KB App Shortcuts leak is in both readings, so it cancels out. `RELOAD_UI_ROUNDS=20` runs more rounds; `RELOAD_UI_SNAPSHOT_ROUNDS="7 20"` saves `vmmap` and `heap` reports to `build/ui-snapshots/` for digging into growth.
- It's XCTest, not Swift Testing: UI testing only exists in XCTest. Its own scheme, `ReloadUITests`, keeps it out of the `Reload` scheme CI tests.
- `scripts/ui-tests.sh` runs it. It refuses while any Reload is running, because XCTest quits running copies of the app it launches, and while the screen is locked, because macOS won't bring the app to the front then.
- **Before each push:** `scripts/install-hooks.sh` (once per clone) sets SSH keep-alives for the repo (git opens its connection before the hook and would lose it during the minutes the tests take) and points git at `.githooks/`, whose `pre-push` runs `scripts/ui-tests.sh` when the push changes `Sources/`, `App/` or `Package.*`. `git push --no-verify` skips it in an emergency.
- The first run asks for Accessibility access for Xcode's test runner (System Settings ▸ Privacy & Security ▸ Accessibility).

## Testing without touching your real setup

- **Unit tests never touch real folders.** Directories are injected (`AppDirectories(root:)` on a temp folder), HTTP goes through `StubHTTPClient`, and downloads through `StubDownloadTransport`.
- **Manual runs:** set `RELOAD_DATA_DIR=<temp folder>`, which works for both the app and the CLI ([app/project.md](app/project.md#reload_data_dir)). Then add a fake installation such as `<tmp>/World of Warcraft/_classic_beta_/Interface/AddOns`.
- **Never** point tests or manual runs at the real WoW folder or `~/Library/Application Support/io.github.miotke.Reload`.
- **Smoke-test and profiling launches** run in the background, stay brief, and are quit afterwards. Never quit a copy of the app you didn't launch.
- **No privileged commands.** Don't run the CLI install's admin prompt yourself ([app/cli-install.md](app/cli-install.md)).
- **Reset first-launch state:**
  - CLI offer: `defaults delete io.github.miotke.Reload didOfferCommandLineTool`
  - Seeding sheet: `defaults delete io.github.miotke.Reload didSeedAddonDetails`

### What the tests cover

- Pure code: TOC parsing edge cases (BOM, CRLF, interface lists, colour codes), TOC suffix splitting, `release.json`, `.build.info`, search ranking against a fixture catalogue.
- Fixtures are invented (made-up repos, descriptions and release notes in the real formats), so they carry no third-party text. Keep it that way when adding new ones.
- `ReleaseSelector` against GitHub-shaped JSON fixtures: no `release.json`, no Forever entry in the newest release, prerelease-only, drafts, `nolib` assets.
- The installer against a temp `AddOns` folder with tiny fixture zips: normal install, an update that drops a folder, conflicts, unmanaged overwrite, zip-slip, and a failure mid-swap that must restore backups.
- One opt-in live test resolves real add-ons against GitHub (`RELOAD_LIVE_TESTS=1`).

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
- After merging app changes into the release branch, add [decision records](decisions/README.md) and update the numbers in [network/budget.md](network/budget.md) and [performance/measurements.md](performance/measurements.md).
- No READMEs in subfolders except `decisions/README.md`, the decision index.
