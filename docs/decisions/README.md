# Decision records

Index of the architecture, network, performance and app decisions behind ForeverAddons, with their status.

Each record explains one decision: its context, what was decided, the alternatives, and the consequences. Current behaviour is in the topic docs ([docs/README.md](../README.md)); records explain *why*.

## Records

| # | Decision | Status | Date |
|---|---|---|---|
| [0000](0000-original-design.md) | Original design (historical) | Superseded by 0001–0014 | 2026-10-11 |
| [0001](0001-swift-package-core.md) | Swift package core with thin app and CLI front ends | Accepted | 2026-10-11 |
| [0002](0002-github-releases-no-keyed-apis.md) | GitHub Releases as the primary source, no keyed APIs | Accepted | 2026-10-11 |
| [0003](0003-forever-detection.md) | Forever detection: `release.json` first, zip TOCs as fallback, one `FlavorRules` table | Accepted; partly superseded by 0016 | 2026-10-11 |
| [0004](0004-transactional-installer.md) | Transactional installer, Trash on uninstall, `flock`-locked JSON store | Accepted | 2026-10-11 |
| [0005](0005-swift-6-concurrency.md) | macOS 27, Swift 6.4, approachable concurrency, `Mutex` | Accepted | 2026-10-11 |
| [0006](0006-bundled-cli-install.md) | Bundle the CLI; symlink install through `osascript` off the main thread | Accepted | 2026-10-11 |
| [0007](0007-real-data-only.md) | Real data only; mock manager removed | Accepted | 2026-10-11 |
| [0008](0008-sqlite-metadata-database.md) | SQLite metadata database via the system SQLite3 API; keep `SearchIndex` over FTS5 | Accepted | 2026-10-11 |
| [0009](0009-local-first-search.md) | Local-first search with a one-request GitHub fallback | Accepted | 2026-10-11 |
| [0010](0010-quota-free-endpoints.md) | Quota-free GitHub endpoints, ~200-repo seed, 2-hour refresh | Accepted | 2026-10-11 |
| [0011](0011-single-cache-owner.md) | One cache owner per kind of data, with `CachePolicy` | Accepted | 2026-10-11 |
| [0012](0012-inspector-and-tables.md) | Inspector inside the detail column; sortable `Table`s | Accepted | 2026-10-11 |
| [0013](0013-screenshot-loading.md) | Screenshot loading: disk cache, thumbnail decode, full size in the viewer | Accepted | 2026-10-11 |
| [0014](0014-docs-layout.md) | Docs as small topic files, an index and decision records | Accepted | 2026-10-11 |
| [0015](0015-environment-only-at-scene-roots.md) | Read `AppModel` from the environment only at scene roots | Accepted | 2026-10-11 |
| [0016](0016-one-flavor-per-game.md) | One flavor per game, rules as data | Accepted | 2026-10-11 |
| [0017](0017-details-without-quota-release-json-by-tag.md) | Details and release notes without API quota; `release.json` stored by tag | Accepted | 2026-10-11 |
| [0018](0018-adoption-suggestions-from-toc-hints.md) | Adoption suggestions from TOC hints and the catalogue | Accepted | 2026-10-12 |
| [0019](0019-available-games-and-visible-row-checks.md) | Show available games instead of a support verdict; check visible rows | Accepted | 2026-10-12 |
| [0020](0020-core-ui-boundary-and-feature-models.md) | Core/UI boundary, feature models and snapshot rendering | Accepted | 2026-10-12 |
| [0021](0021-sidebar-navigation-and-game-picker.md) | Sidebar navigation with library sections and categories; game picker in the title | Accepted | 2026-10-12 |
| [0022](0022-mac-style-settings-and-alternate-icons.md) | Mac-style tabbed Settings; alternate icons through `applicationIconImage` only | Accepted | 2026-10-12 |
| [0023](0023-batched-row-reads-and-sidebar-progress.md) | One query for a Browse list's stored answers; refresh progress observed only in the sidebar | Accepted | 2026-10-12 |

## By area

| Area | Records |
|---|---|
| Architecture | 0001, 0004, 0005, 0008 |
| Sources and flavor support | 0002, 0003, 0016, 0018, 0019 |
| Network | 0009, 0010, 0011, 0017, 0019 |
| App | 0006, 0007, 0012, 0013, 0015, 0019, 0021, 0022, 0023 |
| Performance | 0008, 0013, 0023 |
| Docs | 0014 |

## Writing a new record

- File name: `NNNN-short-title.md`, the next free number.
- 40–100 lines.
- Start with `# NNNN: Title` and a one-sentence summary.
- Sections, in order:
  - **Status:** Accepted / Accepted, landing with the core merge / Superseded by NNNN
  - **Date**
  - **Context**: the problem and the facts (measurements, constraints)
  - **Decision**: what was chosen, concretely
  - **Alternatives considered**: a table of options and why not
  - **Consequences**: what follows, good and bad
- Add a row to the tables above.
- When a decision replaces an older one, set the old one's status to "Superseded by NNNN". Don't delete it.
- Record decisions after merging app changes into `main` (see `.claude/CLAUDE.md`).
