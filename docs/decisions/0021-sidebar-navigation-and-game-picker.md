# 0021 — Sidebar navigation and a game picker in the title

The sidebar became the app's navigation (library sections with counts, Browse and the categories), and switching installations moved into a menu on the window title.

**Status:** Accepted · **Date:** 2026-10-12

## Context

The user asked for this redesign. Before it:
- The sidebar held only the installation list, usually one row, so most of it was empty.
- A segmented Installed/Browse control took the toolbar's centre.
- Browse's category chips took a row of vertical space above the table, and scrolled sideways on narrow windows.
- Installed mixed managed add-ons and unmanaged folders in two table sections; finding the add-ons with updates, or the pinned ones, meant sorting by Status.

## Decision

1. **Game picker in the title.** `toolbarTitleMenu` on the detail view: each installation with its game version as a subtitle and a checkmark on the current one, then **Add Installation…** and **Scan Again**. The selection is remembered in user defaults (not on sandboxed data).
2. **Sidebar sections.** A source-list `List` with selection:
   - Library: Installed, Updates, Unmanaged, Pinned, each with a count badge that hides at zero
   - Browse: Browse, then the categories from `BrowseContent.categories` with their SF Symbols

   The selection is remembered per window (`@SceneStorage`).
3. **Library sections are filters, not new screens.** One `InstalledView` and `InstalledModel`; the section is part of `InstalledOptions`. Sections test what the rows already hold (managed, `availableVersion` from the core's `UpdateOffer`, pinned), so the app adds no decision logic, and the Updates badge equals what Update All installs. Updates has its own **Update All** above the table.
4. **Search follows the section.** It filters a library section as you type; **Search All Add-ons** (a suggestion) or Return takes the text to Browse. In Browse it searches the catalogue; in a category it searches within it (the category's query plus the typed words). The prompt names the section.
5. **Removed:** the segmented control, the category chips, the Managed/Unmanaged table sections and the sidebar's installation list.

Details: [navigation.md](../app/navigation.md).

## Alternatives considered

| Option | Why not |
|---|---|
| Keep the Installed/Browse tabs, add Updates and Pinned as more segments | The toolbar gets crowded and the sidebar stays empty; segments can't show counts |
| Keep categories as chips above Browse | Costs a row of vertical space on every Browse view and scrolls sideways when narrow; the sidebar has room and shows the SF Symbols better |
| Installations in the sidebar above the sections | Most people have one installation; a title menu keeps it reachable without a permanent row |
| A separate model or view per library section | Duplicates cells, context menus and sorting; filters over one row list stay consistent |

## Consequences

- Updates, unmanaged folders and pinned add-ons are one click away, with their counts always visible.
- The toolbar has room; the Browse filter bar only holds Popular / Recently Updated (or the category's name) and the Hide Classic-only toggle.
- Section changes clear the search, so a filter typed in one section doesn't silently apply to the next.
- In snapshots the sidebar's selection highlight is redrawn by the renderer, since `NSVisualEffectView` paints black offscreen.
- Menus don't render offscreen, so the picker's snapshot draws its item labels in a menu-like panel.

## Later ideas

- **Recently viewed:** a Library item listing the add-ons opened in the inspector or their own window.
- **Add-on sets:** named groups (raiding, questing) to install or switch together.
