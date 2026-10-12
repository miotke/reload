# Concurrency

The Swift 6 concurrency settings, where shared state lives, and what may run on the main thread.

Why these settings: [decision 0005](../decisions/0005-swift-6-concurrency.md).

## Language settings

| Target | Settings |
|---|---|
| `AddonKit`, `addonctl`, tests (`Package.swift`) | Swift 6 language mode, strict concurrency, `NonisolatedNonsendingByDefault`, `InferIsolatedConformances` |
| `ForeverAddons` app, app tests (`App/project.yml`) | The same, plus `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` |
| `addonctl` built by Xcode | `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`, to match the package |

Swift tools 6.4, minimum macOS 27.

- `NonisolatedNonsendingByDefault` means a `nonisolated async` function runs on the caller's actor unless marked `@concurrent`.
- In the app, everything is `@MainActor` unless it says otherwise. **Helpers that run off the main thread need `nonisolated`** (for example the Markdown parser and the screenshot decoder).

## Shared state

| Kind | Use |
|---|---|
| Long-lived services with async work | An actor: `AddonManager`, `InstallStore`, `MetadataDatabase`, `Downloader`, `GitHubSource`, the search actors |
| A small value read from several threads | `Mutex` from the Synchronization module |
| App UI state | `@Observable` classes on the main actor |

Never:
- `NSLock`, `os_unfair_lock` or `DispatchQueue` used as a lock
- `@unchecked Sendable` in library code

## Main-thread rules

The main actor only updates UI. Everything else runs elsewhere:

| Work | Where |
|---|---|
| File and network I/O | `AddonManager` and its actors |
| Database reads and writes | `MetadataDatabase` actor; transaction bodies are synchronous, so no write lock spans an `await` |
| JSON decoding, Markdown parsing | `nonisolated` helpers |
| Image decoding | `ScreenshotLoader`, ImageIO off the main actor |
| Privileged CLI install | `osascript` subprocess off the main thread ([cli-install.md](../app/cli-install.md)) |

In the app, views below a scene root get `AppModel` as a property, never from `@Environment`; AppKit-hosted cells and menus can lose the environment during row rebuilds ([decision 0015](../decisions/0015-environment-only-at-scene-roots.md)).

Progress streams use `AsyncStream` with `bufferingNewest` and tick at most 10–20 times a second. More in [performance/guidelines.md](../performance/guidelines.md).

## Cancellation

- Search and refresh return `AsyncStream`s. Cancelling the consumer cancels the work (`onTermination` cancels the task).
- Inspector details are cancelled when the selection changes ([details-and-screenshots.md](../features/details-and-screenshots.md)).
- Concurrent requests for the same download share one task ([installing.md](../features/installing.md#downloader)).
