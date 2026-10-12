# Performance guidelines

The rules for keeping the app fast. Read this before changing hot paths, UI lists or database code.

Each rule comes from `.claude/CLAUDE.md` or a number in [measurements.md](measurements.md).

## Main actor

- **No I/O, database, JSON, Markdown or image decoding on the main actor.** Markdown parsing takes 19 ms and zip extraction 107 ms; either one drops frames.
- App code is `@MainActor` by default, so helpers that run elsewhere need `nonisolated` ([concurrency.md](../architecture/concurrency.md)).

## Database and files

- **Batch writes** in one transaction.
- **Never write when nothing changed.** Compare first.
- **Never hold a write transaction across a network `await`.** Fetch first, then write.
- Avoid whole-file rewrites per change. 1,300 support-cache sets took 4.4 s that way, 1.7 ms batched in SQLite.

### SQLite

| Setting | Why |
|---|---|
| `journal_mode=WAL` | Readers don't block the writer |
| `synchronous=NORMAL` | Safe with WAL, fewer fsyncs |
| `busy_timeout` | The app and CLI can both have it open |
| `journal_size_limit` | The WAL grew to 4.9 MB in the audit |
| Persistent prepared statements | 6.6 ms vs 64 ms for a 2.4k-row upsert |
| `WITHOUT ROWID` where it fits | Tables keyed by text such as `owner/repo` |
| `PRAGMA optimize` on close | Keeps the query planner's statistics fresh |

## Progress and observation

- **Progress at most 10–20 Hz.** Use `AsyncStream` with `bufferingNewest` so slow consumers see the latest value, not a backlog.
- **Per-row `@Observable` state.** Progress and errors live in one `RowState` per row, so a tick re-renders only that row's cells and the inspector's action bar.
- Keep refresh progress in its own object (`RefreshStatus`), observed only by the sidebar bar and the seeding sheet.
- Assign model properties only when the value changed.

## Tables and lists

- **Sort and filter in the model, never in `body`.**
- `Table`s use **stable IDs** and rows of **pre-formatted strings** (`BrowseRow`, `InstalledRow` are flat `Equatable` values built in `InstallationModel`).
- **No `ViewThatFits` or `GeometryReader` in cells.** They lay out every row more than once.
- Debounce work triggered by selection (details wait 250 ms).

## Images

- **Decode thumbnails at display size** with ImageIO (`kCGImageSourceThumbnailMaxPixelSize`). Full resolution only in the viewer.
- Keep decoded images in an `NSCache`.
- Use a **dedicated `URLCache`** for image bytes (32 MB memory, 200 MB disk) under the app's Caches folder, never a shared `~/Library/Caches` folder.
- Read bodies in the chunks the session delivers, never byte by byte; decode off the loader's actor, a few at a time.
- **Cancel loads when the selection changes** (`.task(id:)`).

Details: [details-and-screenshots.md](../features/details-and-screenshots.md#screenshots).

## Network

The network has its own rules: [network/overview.md](../network/overview.md). The short version: read local data first, cache everything, and stay within 4 concurrent requests.

## Checklist for a change

| Question | If yes |
|---|---|
| Does it run on every keystroke or progress tick? | Measure it against [measurements.md](measurements.md) |
| Does it touch disk or decode data? | Move it off the main actor |
| Does it write to the database? | Batch it and skip unchanged rows |
| Does it add a column or cell? | Pre-format the value in the row |
| Does it load an image? | Thumbnail decode, cache, cancel |
