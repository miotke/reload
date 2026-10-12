# First launch and refresh

What happens the first time the app opens (the seeding sheet and the CLI offer), and how refreshes run afterwards: progress, the 2-hour timer and manual checks.

Code: `App/ForeverAddons/Models/AppModel.swift`, `Views/SeedingSheet.swift`, `AddonManager.refresh(in:force:)`. What a refresh fetches: [network/overview.md](../network/overview.md).

> `refresh(in:force:)` and `lastRefresh(in:)` are placeholders on this branch (refresh only checks installed add-ons; `lastRefresh` is always `nil`). The real versions land with the core merge.

## Sequence

```mermaid
flowchart TD
    L[App launches] --> Q{Completed refresh?<br/>lastRefresh != nil<br/>or didSeedAddonDetails}
    Q -- no --> S[Seeding sheet<br/>refresh force: true]
    S --> D[Sheet closes when finished<br/>or Continue in Background after 3 s]
    D --> C{CLI offered before?<br/>didOfferCommandLineTool}
    Q -- yes --> R[refresh force: false]
    R --> C
    C -- no, real data --> O[Offer to install addonctl]
    C -- yes --> T[2-hour timer]
    O --> T
```

## Seeding sheet

- Shown when no refresh has ever completed: `lastRefresh(in:) == nil` and no `didSeedAddonDetails` flag.
- Title "Gathering Add-on Details". It blocks the window with a determinate progress bar, the current step and "n of m".
- It closes when the refresh finishes. After 3 seconds, **Continue in Background** lets you in while it keeps going.
- On sandboxed data (`ADDONS_DATA_DIR`) the flag isn't stored, so only `lastRefresh` decides.
- To see it again: `defaults delete com.andrewmiotke.ForeverAddons didSeedAddonDetails`.

## Refresh progress

`refresh` emits `RefreshProgress` values through three phases, then `.finished`:

| Phase | Work | Share of the bar |
|---|---|---|
| `catalogue` | download the add-on catalogue | 0–10% |
| `updates` | check installed add-ons for updates | 10–30% |
| `support` | check which add-ons support Forever | 30–100% |
| `finished` | carries the update states | 100% |

- `.finished` carries the update states, which replace the Installed statuses.
- During the support phase the Browse lists are re-read at most every 2 s so badges fill in.
- Progress lives in `RefreshStatus`, observed only by the sidebar bar and the seeding sheet.

### Sidebar progress

While a refresh reports progress, a small bar and message sit under **Add Installation…**. Throttled refreshes that finish at once never show it.

## When refreshes run

| Trigger | Call |
|---|---|
| First launch | `refresh(force: true)` behind the seeding sheet |
| Launch, app activation, every 2 h while running | `refresh(force: false)`; the core throttles it, so it's cheap |
| Check for Updates (⌘R, toolbar, menu bar extra) | `refresh(force: true)` |

- The 2-hour timer is one task, restarted when the selected installation changes and skipped while a refresh is running.
- Automatic refreshes can be turned off in Settings (**Check for updates automatically**, key `checkForUpdatesOnLaunch`).

## CLI install offer

After the seeding sheet closes, the app offers once to install `addonctl` (unless it's already installed). Only on real data. Details: [cli-install.md](cli-install.md).
