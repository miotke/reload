# 0028: Minimum macOS 26, Apple silicon only

Reload now runs on macOS 26 or later and builds with Xcode 26 or later (Swift tools 6.2). It stays Apple silicon only.

- **Status:** Accepted
- **Date:** 2026-10-12

## Context

[Decision 0005](0005-swift-6-concurrency.md) targeted macOS 27 and Swift 6.4 because the project was new and had no users. With public releases, macOS 27 shut out everyone who hadn't upgraded, and GitHub's runners have no Xcode 27, so the release workflow couldn't build.

Lowering the deployment target to 26.0 and building with the macOS 27 SDK produced no availability errors or warnings. The code has no `#available` checks and uses nothing from Swift 6.3 or 6.4. Its concurrency features (`NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, `@concurrent`, `isolated deinit`) all exist in Swift 6.2.

## Decision

- **Deployment target macOS 26.0** in `Package.swift` (`.macOS(.v26)`) and `App/project.yml`.
- **Swift tools 6.2** (`swift-tools-version: 6.2`), so Xcode 26 can build it. The language mode and concurrency settings from 0005 are unchanged.
- **`ARCHS: arm64`.** Unlike 27, macOS 26 still runs on some Intel Macs, so Xcode would build a universal app by default. Reload stays Apple silicon only.
- **CI runs on `macos-26`** and selects Xcode 26 or later.
- New APIs from macOS 27 or later need an `if #available` fallback.

## Alternatives considered

| Option | Why not |
|---|---|
| Stay on macOS 27 | Excludes most current Macs, and CI can't build until GitHub ships Xcode 27 |
| Universal build for Intel Macs on macOS 26 | A shrinking set of machines to test and support for a game client that runs best on Apple silicon |
| Go lower than macOS 26 | Not checked; macOS 26 covers the Macs that matter for now, and every older version adds testing |

## Consequences

- More people can run Reload, and the tag-triggered release workflow can build and draft releases on GitHub.
- Contributors can use Xcode 26.
- Using a macOS 27 API now takes an availability check, and the fallback needs testing on macOS 26.
