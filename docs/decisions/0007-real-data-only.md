# 0007: Real data only in the app

The app always runs against the real `AddonManager`; the mock manager, SwiftUI previews with sample data and the `-UseMockData` launch flag were removed.

- **Status:** Accepted
- **Date:** 2026-10-11

## Context

Early app work used a mock `AddonManaging` implementation with sample add-ons, wired into SwiftUI previews and a `-UseMockData` launch argument. It let the UI be built before the core was finished.

Once the real core worked, the user asked for the mock to be removed so the app only ever shows real data. A mock is a second code path that has to be kept in step with the real streams, errors and timing, and it hides problems that only show with real data, such as slow refreshes, large lists and rate limits.

## Decision

- Remove the mock manager, the sample data, the previews that used them, and `-UseMockData`.
- The app target contains **no mock managers or sample data**.
- For safe testing, use real code with a sandboxed data folder: `ADDONS_DATA_DIR=<tmp>` plus a fake WoW folder.
- Unit tests inject stubs at the core's protocol seams (`StubHTTPClient`, `StubDownloadTransport`), not a mock manager.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep the mock for previews only | Still drifts; previews show impossible states |
| Keep `-UseMockData` for demos | Same drift, plus a second wiring path in `AppEnvironment` |
| Record real responses into fixtures for the app | More machinery than `ADDONS_DATA_DIR` |

## Consequences

- What you see while developing is what users get.
- SwiftUI previews aren't available for views that need a manager.
- Manual testing needs a temp folder and, for some flows, a network connection.
- `ADDONS_DATA_DIR` became the supported way to test the app ([app/project.md](../app/project.md#addons_data_dir)).

## See also

- [development.md](../development.md#testing-without-touching-your-real-setup)
- [app/project.md](../app/project.md#addons_data_dir)
- `.claude/CLAUDE.md`, "Code": no mock managers or sample data in the app target
