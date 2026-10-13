# 0005: macOS 27, Swift 6.4 and approachable concurrency

Target the latest platform and language: macOS 27, Swift tools 6.4, Swift 6 strict concurrency with the approachable-concurrency features, the app on the main actor by default, and `Mutex` instead of locks.

- **Status:** Accepted; the minimum macOS and Swift tools version are superseded by [0028](0028-macos-26-minimum.md)
- **Date:** 2026-10-11

## Context

This is a new project with no users on older systems. It does a lot of concurrent work (downloads, update checks, support checks, file watching) shared between actors and the UI. Data races here would corrupt the store or the add-ons folder.

Swift 6.2 added "approachable concurrency" features that make the strict model easier to live with: async functions run on the caller's actor by default, and conformances can be inferred as isolated.

## Decision

- Minimum **macOS 27**, built with **Swift tools 6.4** in **Swift 6 language mode** with strict concurrency.
- Every package target enables `NonisolatedNonsendingByDefault` and `InferIsolatedConformances`.
- The app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`. Off-main helpers are marked `nonisolated`. The Xcode `reload` target stays `nonisolated` to match the package.
- Shared mutable state lives in **actors** (`AddonManager`, `InstallStore`, `Downloader`, `GitHubReleaseResolver`, search actors), or **`Mutex`** from the Synchronization module for small values.
- No `NSLock` and no `@unchecked Sendable` in library code.

## Alternatives considered

| Option | Why not |
|---|---|
| Support older macOS | No need; costs availability checks and older APIs |
| Swift 5 mode or minimal checking | Races found at runtime instead of compile time |
| App code `nonisolated` by default | Most app code is UI; marking everything `@MainActor` is noise |
| `NSLock` / `os_unfair_lock` | Needs `@unchecked Sendable`; `Mutex` is checked by the compiler |

## Consequences

- The compiler catches data races in the core and the app.
- Heavy work in the app must be explicitly `nonisolated` (Markdown parsing, image decoding), which makes main-thread work visible in review.
- Contributors need Xcode 27.
- Some patterns (blocking subprocesses, see [0006](0006-bundled-cli-install.md)) have to move off the main actor explicitly.

## See also

- [architecture/concurrency.md](../architecture/concurrency.md)
- [performance/guidelines.md](../performance/guidelines.md)
