# Required add-ons in the app

How the app shows add-ons that need other add-ons: the Installed warning, the inspector's Requires section, the offer to install them after an install, and the warning before removing one that others need. What counts as missing, the candidates and the one `suggested` are the core's ([dependencies.md](../features/dependencies.md)); the app only maps them.

Code: `App/Reload/Support/DependencySupport.swift` (wording, `DependencyFollowUp`, `DependencyPrompt`), `Models/InstalledModel.swift` (loading), `Models/UpdateQueue.swift` (follow-up, removal dependents), `Views/RequiresSection.swift`, `Views/ContentView.swift` (the prompt). Settings: [settings.md](settings.md#dependencies).

## Installed warning

- `InstalledModel.reload()` asks `missingDependencies(in:)` after `addons(in:)`, every reload (local; installing a missing add-on by hand changes it without changing the managed list). The result is indexed by requiring add-on, keyed like the managed list (lower-cased ref), and applied in the same row rebuild as the add-ons.
- A row whose add-on needs something gets `InstalledRow.missingDependencies` (folders), `dependencyText` and `dependencyHelp`, built with the row so the cell only reads strings.
- Status: **Needs BigWigs** (one folder) or **Needs 2 add-ons**, orange with a warning triangle; the tooltip lists them: "BigWigs isn't installed. The game won't load LittleWigs until it is."
- Condition `missingDependencies` sorts right after missing files and before updates: the add-on doesn't load at all. An add-on with an update still shows in Updates (that section filters on the offer, not the status). Sidebar counts don't change.

## Inspector: Requires

Shown for installed add-ons that need something, after the details (`RequiresSection`).

| The core reports | The section shows |
|---|---|
| a `suggested` candidate | **Install BigWigs** and the candidate's reason |
| candidates, none suggested | each candidate with its reason and **Install** |
| no candidates | "No add-on in the catalogue provides it." and **Search**, which opens Browse searching for the folder. The inspector clears at once, so the add-on that asked doesn't look like the answer; when the search finishes, its first result is selected, or nothing when it found none (`BrowseModel.revealQuery`). Typing another search first cancels that |

- Every Install goes through `UpdateQueue.install`, so progress and errors show on the candidate's own row state, as in Browse, and its own dependencies are followed up in turn.
- In an add-on window, Search switches the main window to Browse.

## After an install

After any install from the app (Browse, the inspector, the Requires section, adopt), `UpdateQueue.followUpDependencies(of:)` asks `missingDependencies(of:in:)` for that add-on and applies the policy (`DependencyFollowUp`):

| Policy (Settings ▸ General) | What happens |
|---|---|
| Ask to install it (default) | one alert at the window root: "LittleWigs needs BigWigs" / "Install BigWigs too?", **Install** and **Not Now** |
| Install it automatically | the suggested add-ons install one after another through the queue |
| Only show a warning | nothing beyond the Installed warning |

- Only `suggested` candidates are ever offered or installed. Folders without one never prompt; they only show in the inspector.
- Several missing folders make one prompt; one add-on that ships several of them is offered once.
- Add-ons already installed or installing are skipped.
- The alert (`AppModel.pendingDependencies`) waits for the Adopt sheet to close, since adopting can raise it. An adopt's follow-up isn't awaited, so the sheet closes first.

## Removing an add-on others need

- With **Warn before removing an add-on others need** on (default), Uninstall… first asks `dependents(of:in:)` (`UpdateQueue.removalDependents`). Off, it doesn't ask.
- The confirmation's message leads with them: "LittleWigs needs BigWigs and will stop loading." Up to three names, then "and N others" (`DependencyWording.list`).
- Both uninstall confirmations use it: the window's (`AppModel.requestUninstall`, from the context menu) and the inspector's own.

## Tests

`DependencyTests` covers the wording, rows, each policy and the removal message, and the models over the test-only `FixtureManager` (which reports LittleWigs needing BigWigs). Snapshots: `installed-rows` (Needs BigWigs), `inspector-requires` (all three kinds) and `settings-general`.
