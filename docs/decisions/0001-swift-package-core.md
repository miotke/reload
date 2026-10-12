# 0001: Swift package core with thin front ends

All logic lives in one Swift package library, `AddonKit`; the SwiftUI app and the `addonctl` CLI are thin front ends sharing `AddonManager` and one install store.

- **Status:** Accepted
- **Date:** 2026-10-11

## Context

ForeverAddons needs both a Mac app and a real package-manager CLI, not a debugging tool. Anything the app can do should work from the terminal, and the reverse. Users will run both at once: install from the terminal while the app is open.

If each front end had its own logic, they would drift: different release choices, different safety checks, and two views of what's installed.

## Decision

- A Swift package (`Package.swift`) with:
  - `AddonKit`, a library holding every rule: finding WoW, choosing releases, downloading, installing, the store and search.
  - `addonctl`, an executable over `AddonKit`.
- The SwiftUI app (`App/`) depends on the `AddonKit` package product.
- Both front ends go through one façade, the `AddonManager` actor (protocol `AddonManaging`).
- Both read and write **one install store** in Application Support, and later one metadata database.
- Pure code (parsers, flavor rules, release selection) is separated from I/O and tested with fixtures.

## Alternatives considered

| Option | Why not |
|---|---|
| App-only, CLI later as a wrapper around the app | The CLI would depend on a running app or duplicate code |
| Logic in the app target, CLI as a second Xcode target sharing files | Hard to test without the app; no SwiftPM `swift test` |
| Separate stores for app and CLI | Two sources of truth; installs from one invisible to the other |

## Consequences

- `swift test` covers the core and the CLI without Xcode.
- The app and the CLI stay equal; new features land in `AddonKit` first.
- The store must be safe across processes, which led to `flock` locking ([0004](0004-transactional-installer.md)).
- The app must notice CLI changes, so it watches the store folder ([app/layout.md](../app/live-data.md#live-updates-from-addonctl-installs)).
- Every dependency of `AddonManager` is injectable, so tests never touch real folders or the network.

## See also

- [architecture/core.md](../architecture/core.md)
- [overview.md](../overview.md)
