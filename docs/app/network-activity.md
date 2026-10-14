# Network Activity window

Window ▸ Network Activity (⌥⌘A): every request and download the core makes, as it happens, so you can see what Reload is fetching and from where.

Code: `Sources/AddonKit/Support/NetworkActivity.swift` (core), `App/Reload/Models/NetworkActivityModel.swift`, `App/Reload/Views/NetworkActivityView.swift`.

## Where the events come from

Every request already goes through two choke points, so recording happens there and nowhere else:

| Wrapper | Wraps | Kind |
|---|---|---|
| `RecordingHTTPClient` | the `HTTPClient` `AddonManager` is given: API calls, `HEAD releases/latest`, `release.json`, catalogue and listings, READMEs, live search | `request` |
| `RecordingDownloadTransport` | the `DownloadTransport`: add-on zips | `download` |

- `AddonManager.init` wraps both before handing them to anything, so tests and the CLI record too.
- `NetworkActivityLog` keeps the last 500 events in memory (`capacity`) behind a `Mutex`; nothing goes to disk.
- Each request is reported twice with the same `id`: when it starts (`finishedAt` nil) and when it ends, with the status, body size (file size for downloads), where redirects ended (`finalURL`) or the error.
- `AddonManaging.networkActivity()` replays the recent events, then streams new ones. It's the app's only way in: the window never reaches into the core.

## The window

- A single-instance `Window` scene, so SwiftUI lists it in the **Window** menu, the Mac convention for tool windows (Safari's Downloads, Xcode's Devices). Shortcut ⌥⌘A.
- `AppModel.activity` starts following the stream at launch, so opening the window mid-refresh shows what already happened.
- **Columns:** Time, Method, Host, Path (query included, truncated in the middle, full URL on hover), Status, Size, Duration. Newest first.
- **Status:** the HTTP code, with "→ host" when a redirect ended elsewhere; "Waiting…" or "Downloading…" while in flight; "Done" for a finished download; the error in red. Codes 400 and up are red too.
- **Toolbar:** All / Downloads (downloads are add-on zips only), and **Clear**. Clearing ignores late finishes of requests it removed.
- **Subtitle:** "214 requests · 3 downloads · 6.1 MB" for what's listed.
- Right-click ▸ **Copy URL** (or URLs).

## Performance

A refresh starts hundreds of requests, so the model never touches the table per event:
- Arrivals are queued and applied at most every 100 ms (`interval`), as one array change.
- Rows are formatted once when their event arrives (`ActivityRow`); cells only read strings.
- At most 1,000 rows are kept; the oldest go first.
- Filtering happens in the model when the switch or the rows change, never in `body`.

## Not done yet

- No per-request detail (headers, timings) or export.
- The CLI doesn't print the log; a `--verbose` flag could read the same `NetworkActivityLog`.
