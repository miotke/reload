<p align="center">
  <img src="App/Design/AppIcon-1024.png" width="160" alt="Reload app icon">
</p>

<h1 align="center">Reload</h1>

A native macOS add-on manager for **World of Warcraft: Forever**, written in Swift. It's a SwiftUI app with a package-manager-style command-line tool (`reload`) built in. Both share the same core library and the same list of installed add-ons, so changes made in one show up in the other.

> **Status: early development.** Expect rough edges, and try it on a copy of your AddOns folder first.

## Features

- **Search** for add-ons, with each result showing whether it supports Forever.
- **Install, update, remove, pin and roll back** add-ons, from the app or the terminal.
- **Install safely.** Installs are transactional and restore the previous version if anything fails. Removed add-ons go to the Trash. Folders the app doesn't manage are never overwritten without asking.
- **Adopt** add-ons you installed by hand.
- **No API keys needed.** Add-ons come from GitHub Releases. You can add your own GitHub token in Settings to raise rate limits.

## Requirements

- macOS 27 or later
- Xcode 27 or later (Swift 6.4)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), only if you change `App/project.yml`

## Build and run the app

1. Clone the repo and open the Xcode project:

   ```sh
   git clone git@github.com:miotke/reload.git
   cd reload
   open App/Reload.xcodeproj
   ```

2. In Xcode's toolbar, choose the **Reload** scheme and **My Mac** as the run destination.
3. Press **⌘R** (Product ▸ Run).

   Xcode resolves the Swift packages (ZIPFoundation and swift-argument-parser) the first time, which takes a minute. The app is signed for local running ("Sign to Run Locally"), so you don't need an Apple developer account.

### First launch

- **Command-line tool.** The app asks whether to install `reload`. Choose **Install** and enter your admin password. This creates a link at `/usr/local/bin/reload` pointing to the tool inside the app, so the tool stays up to date when the app does. Choose **Not Now** to skip it; you can install it later from **Settings ▸ Command Line**.
- **Finding WoW.** The app looks for World of Warcraft automatically. If it can't find your Forever install, click **Add Installation…** and choose the Forever folder. During the beta that's `World of Warcraft/_classic_beta_`.

### Building outside Xcode

You can also build and launch the app from the terminal:

```sh
xcodebuild -project App/Reload.xcodeproj -scheme Reload \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Reload.app
```

If `xcode-select -p` points to the Command Line Tools instead of Xcode, either run `sudo xcode-select -s /Applications/Xcode.app` once, or put `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in front of each command.

### Developer options

| Option | What it does |
|---|---|
| `RELOAD_DATA_DIR=/some/dir` (environment variable) | Keeps all app data (installed add-on list, caches) in that folder and skips automatic WoW detection. Useful for testing against a fake WoW folder. In Xcode, set it under Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments. The CLI honours it too. |

See [`docs/app/project.md`](docs/app/project.md) for how the Xcode project is generated and how the app is put together.

## Command-line tool

After installing it from the app:

```console
$ reload search boss
$ reload install BigWigsMods/BigWigs
$ reload outdated
$ reload update
$ reload rm bigwigs
$ reload --help
```

Every command supports `--json` for scripting. See [`docs/cli/commands.md`](docs/cli/commands.md) for every command and [`docs/cli/output.md`](docs/cli/output.md) for options and exit codes.

To build the CLI on its own without the app:

```sh
swift build -c release --product reload
.build/release/reload --help
```

## How it finds Forever builds

Most popular add-ons are published with the [BigWigs packager](https://github.com/BigWigsMods/packager). The packager attaches a `release.json` to each GitHub release, listing which game versions the zip supports. Reload picks the newest release whose `release.json` includes `flavor: "forever"`. If a release has no `release.json`, it looks inside the zip for Forever TOC files (`_Camelot.toc` or `-Forever.toc`) or an `## Interface:` value in the `16xxx` range.

Search draws on the community [github-wow-addon-catalogue](https://github.com/layday/github-wow-addon-catalogue) by layday (GPL-3.0), which the app downloads at runtime and never bundles; your installed add-ons; and, on demand, GitHub's search API.

## Documentation

Everything is in [`docs/`](docs/README.md), which lists every doc. Start with [`docs/overview.md`](docs/overview.md) for how the pieces fit together, or [`docs/development.md`](docs/development.md) to work on the code.

## Development

```
Package.swift            AddonKit library, reload CLI, tests
Sources/AddonKit/        core: models, parsers, GitHub source, installer, store, search, AddonManager
Sources/reload/          command-line tool
Tests/                   Swift Testing suites + fixtures
App/                     SwiftUI app (Xcode project generated by XcodeGen from project.yml)
docs/                    documentation (index in docs/README.md)
```

Run the core and CLI tests:

```sh
swift test
```

The tests that hit real GitHub are opt-in:

```sh
RELOAD_LIVE_TESTS=1 swift test
```

## Acknowledgements

The design borrows heavily from [instawow](https://github.com/layday/instawow) and [WowUp](https://github.com/WowUp/WowUp), and depends on the [BigWigs packager](https://github.com/BigWigsMods/packager) ecosystem. Libraries: [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (MIT) and [Swift Argument Parser](https://github.com/apple/swift-argument-parser) (Apache 2.0).

## License

Reload is released under the [MIT License](LICENSE).

Reload is not affiliated with or endorsed by Blizzard Entertainment. World of Warcraft and Warcraft are trademarks or registered trademarks of Blizzard Entertainment, Inc. Add-ons are made and published by their own authors; Reload only downloads them from GitHub.
