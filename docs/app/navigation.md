# Navigation

How you move around the main window: the game picker in the title, the sidebar's sections and categories, and what the toolbar search applies to.

Code: `App/Reload/Views/SidebarView.swift` (sidebar, title menu), `Support/SidebarSections.swift` (sections, counts, search scope), `Models/AppModel.swift` (`section`, `searchText`). Why: [decision 0021](../decisions/0021-sidebar-navigation-and-game-picker.md). The rest of the window: [layout.md](layout.md).

## Game picker

The window title is the selected installation's name ("Forever Beta"), with the update summary as its subtitle. Clicking it opens a `toolbarTitleMenu`, the native title menu:

```
 ✓ Forever Beta
   1.60.1.70338
   Classic Era
   1.15.7.61582
 ─────────────────
   Add Installation…
   Scan Again
```

- Each installation shows its display name with the game version (or folder name) as the item's subtitle; the current one has a checkmark.
- The selection is remembered in user defaults (`selectedInstallation`), except on sandboxed data (`RELOAD_DATA_DIR`), so a temporary run never replaces it. A remembered installation that's gone falls back to the first.
- Switching clears both tables' selections; refreshes still run only on launch, activation, ⌘R and the 2-hour timer.
- With no installation, the detail area offers **Add Installation…** and **Scan Again** instead.

## Sidebar

A source-list `List` with selection, for the selected installation:

| Section | Item | Shows | Badge |
|---|---|---|---|
| Library | **Installed** | managed add-ons | managed count |
| | **Updates** | managed add-ons with an update offer, **Update All** above the table | update count |
| | **Unmanaged** | folders Reload didn't install; Adopt… and Move to Trash… | folder groups |
| | **Pinned** | pinned add-ons | pinned count |
| Browse | **Browse** | Popular / Recently Updated, or search results | — |
| | Boss mods, Bags, UI, Quests, Maps, Auction, Combat | that category's saved query | — |

- Badges count rows before the search filter and hide at zero.
- The categories (titles, SF Symbols, queries) come from `BrowseContent.categories`, falling back to the core's `SearchAliases.categories` until Browse has loaded.
- The selection is remembered per window (`@SceneStorage("sidebarSelection")`, e.g. `updates` or `category:bags`).
- The [refresh progress bar](first-launch.md#sidebar-progress) sits at the bottom.
- `SidebarView` takes the selection binding, counts, categories and refresh progress as plain values, so it never reads `AppModel` from the environment.

### Library sections are one table

Installed, Updates, Unmanaged and Pinned are the same `InstalledView`, cells and context menus. `InstalledModel` builds every row once, counts each section (`LibraryCounts`), then keeps the selected section's rows that match the search, sorted (`InstalledOptions.section`). Which rows belong where is display mapping over what the rows already hold:

| Section | Row test (`LibrarySection.includes`) |
|---|---|
| Installed | managed |
| Updates | managed and `availableVersion` set, i.e. the core's `UpdateOffer` exists (pinned add-ons never have one) |
| Unmanaged | not managed |
| Pinned | managed and pinned |

So the Updates badge always equals `updateCount`, which Update All installs. Switching between library sections clears the table selection, since the row may not be in the next one.

Empty sections explain themselves: "No Updates" ("Every add-on is up to date", or "Check for updates with ⌘R" before the first check), "No Unmanaged Folders", "No Pinned Add-ons", "No Managed Add-ons" with **Browse Add-ons**.

### Sidebar footer

Under the refresh progress bar (shown while a refresh runs), **Last fetched Oct 12, 7:18 AM** ("Today, 7:18 AM", or "Not fetched yet") from `lastRefresh(in:)`, and a ⟳ button that runs a forced refresh like ⌘R; it's a spinner and disabled while one runs (`FetchFooter`).

## Appearance

Settings ▸ Appearance and **View ▸ Appearance** pick Use System Setting, Light or Dark (`AppAppearance`, stored as `appearance`). It sets `NSApp.appearance`, so window chrome, sheets and menus follow, not just SwiftUI content.

## Search scope

One toolbar search field (⌘F), whose prompt follows the section: "Filter installed add-ons", "Filter updates", "Filter unmanaged folders", "Filter pinned add-ons", "Search add-ons", "Search Bags".

| Section | Typing… |
|---|---|
| Library | filters the section's rows by name, repository and folders, as you type. The suggestion **Search All Add-ons for "…"**, or Return, jumps to Browse with the same text |
| Browse | searches the catalogue (local first, [search.md](../features/search.md)) |
| Category | searches within it: the category's query plus the typed words (`bag` + `sort` → `bag sort`; every word must match) |

- Changing section clears the search, so each section starts unfiltered; "Search All Add-ons" carries the text over.
- A library section with no matches offers **Search All Add-ons** too.
- `SidebarItem.browseQuery(typed:categories:)` and `searchPrompt(categories:)` hold these rules; `SidebarSectionTests` covers them.

## Toolbar

- Library sections: ⟳ Check for Updates (⌘R) and Update All (not on Updates, which has its own above the table).
- Always: the inspector toggle (⌥⌘I) and the search field.
- Browse's filter bar holds Popular / Recently Updated (empty query) or the selected category's name. Which games show is a setting, not a toolbar control ([layout.md](layout.md#browse-table)).
