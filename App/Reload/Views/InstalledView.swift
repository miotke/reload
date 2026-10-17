import AddonKit
import AppKit
import SwiftUI

/// One library section (docs/app/navigation.md): managed add-ons with update status, those
/// with an update, unmanaged folders that can be adopted, or pinned add-ons. One sortable table
/// whose rows `InstalledModel` filters by section and query.
struct InstalledView: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var installed: InstalledModel
    var queue: UpdateQueue
    var inspector: InspectorModel
    var section: LibrarySection
    /// The toolbar search, trimmed.
    var query: String

    @AppStorage("installedSort") private var sortStorage = ColumnSort(InstalledColumn.name).storageValue
    @SceneStorage("installedColumns") private var columns = TableColumnCustomization<InstalledRow>()

    private var sort: ColumnSort<InstalledColumn> {
        ColumnSort(storageValue: sortStorage) ?? ColumnSort(.name)
    }

    private var sortOrder: Binding<[ColumnSort<InstalledColumn>]> {
        Binding(
            get: { [sort] },
            // Keeps the current sort if the table ever reports an empty order.
            set: { if let first = $0.first { sortStorage = first.storageValue } })
    }

    /// Filtering and sorting happen in the model, once per change, not in `body`.
    private var options: InstalledOptions { InstalledOptions(query: query, section: section, sort: sort) }

    var body: some View {
        VStack(spacing: 0) {
            if section == .updates && installed.counts.updates > 0 {
                UpdatesHeader(count: installed.counts.updates, isUpdating: queue.isUpdatingAll) {
                    Task { await queue.updateAll() }
                }
                Divider()
            }
            table
                .overlay { emptyState }
        }
        .onChange(of: options, initial: true) { installed.options = options }
    }

    private var table: some View {
        @Bindable var inspector = inspector
        return Table(of: InstalledRow.self, selection: $inspector.selectedAddonID, sortOrder: sortOrder,
              columnCustomization: $columns) {
            TableColumn("Name", sortUsing: ColumnSort(InstalledColumn.name)) { row in
                InstalledNameCell(row: row)
            }
            .width(min: 160, ideal: 260)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Version", sortUsing: ColumnSort(InstalledColumn.version)) { row in
                VersionCell(row: row)
            }
            .width(min: 80, ideal: 150, max: 260)
            .customizationID("version")

            TableColumn("Channel", sortUsing: ColumnSort(InstalledColumn.channel)) { row in
                ChannelCell(row: row)
            }
            .width(min: 60, ideal: 80, max: 110)
            .customizationID("channel")

            TableColumn("Status", sortUsing: ColumnSort(InstalledColumn.status)) { row in
                StatusCell(row: row, flavor: installed.installation.flavor)
            }
            // Wide enough for "Not loaded by Forever" and the classics' longer names.
            .width(min: 90, ideal: 160, max: 220)
            .customizationID("status")

            TableColumn("Installed", sortUsing: ColumnSort(InstalledColumn.installed, order: .reverse)) { row in
                InstalledDateCell(row: row)
            }
            .width(min: 70, ideal: 96, max: 130)
            .customizationID("installed")

            TableColumn("") { row in
                InstalledActionCell(queue: queue, row: row, rowState: queue.row(row.id)) {
                    model.adoptTarget = installed.status(id: row.id).flatMap(AdoptTarget.init)
                }
            }
            .width(min: 84, ideal: 100, max: 160)
            .customizationID("action")
            .disabledCustomizationBehavior(.visibility)
        } rows: {
            ForEach(installed.rows) { TableRow($0) }
        }
        .contextMenu(forSelectionType: AddonStatus.ID.self) { ids in
            if let id = ids.first, let status = installed.status(id: id) {
                InstalledContextMenu(model: model, installed: installed, queue: queue, inspector: inspector,
                                     status: status, openWindow: openWindow)
            }
        } primaryAction: { ids in
            // Double-click or Return. Unmanaged folders have no details to open.
            guard let id = ids.first else { return }
            if let ref = AddonRef(rowID: id), installed.addon(for: ref) != nil {
                openWindow(id: AddonWindowID.sceneID, value: AddonWindowID(ref: ref, installationID: installed.installation.id))
            } else {
                inspector.selectedAddonID = id
                model.showInspector = true
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if installed.addons.isEmpty {
            if installed.isLoading || !installed.hasLoaded {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("No Add-ons", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Nothing is installed in \(installed.installation.addonsDirectory.path(percentEncoded: false)) yet.")
                } actions: {
                    Button("Browse Add-ons") { model.section = .browse }
                }
            }
        } else if installed.rows.isEmpty {
            if !query.isEmpty {
                ContentUnavailableView {
                    Label("No Results for “\(query)”", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing in \(section.title) matches. Search every add-on instead?")
                } actions: {
                    Button("Search All Add-ons") { model.searchAllAddons() }
                }
            } else if installed.counts[section] == 0 {
                emptySection
            }
        }
    }

    /// The selected section has nothing in it, though the installation has add-ons.
    @ViewBuilder private var emptySection: some View {
        switch section {
        case .installed:
            ContentUnavailableView {
                Label("No Managed Add-ons", systemImage: LibrarySection.installed.symbol)
            } description: {
                Text("Install add-ons from Browse, or adopt the folders in Unmanaged.")
            } actions: {
                Button("Browse Add-ons") { model.section = .browse }
            }
        case .updates:
            ContentUnavailableView(
                "No Updates", systemImage: "checkmark.circle",
                description: Text(queue.lastChecked == nil ? "Check for updates with ⌘R." : "Every add-on is up to date."))
        case .unmanaged:
            ContentUnavailableView(
                "No Unmanaged Folders", systemImage: LibrarySection.unmanaged.symbol,
                description: Text("Reload manages every folder in AddOns."))
        case .pinned:
            ContentUnavailableView(
                "No Pinned Add-ons", systemImage: LibrarySection.pinned.symbol,
                description: Text("Pin an add-on from its context menu to keep it at its current version."))
        }
    }
}

/// Above the Updates section's table: how many updates there are, and Update All.
struct UpdatesHeader: View {
    var count: Int
    var isUpdating: Bool
    var updateAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(count == 1 ? "1 update available" : "\(count) updates available")
                .font(.headline)
            Spacer()
            if isUpdating { ProgressView().controlSize(.small) }
            Button("Update All", systemImage: "square.and.arrow.down.on.square", action: updateAll)
                .buttonStyle(.borderedProminent)
                .disabled(isUpdating)
                .help("Update every add-on that has an update, whatever the filter")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Cells

struct InstalledNameCell: View {
    var row: InstalledRow

    var body: some View {
        HStack(spacing: 6) {
            Text(row.name).fontWeight(.medium).lineLimit(1).layoutPriority(1)
            if let subtitle = row.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(row.subtitle.map { "\(row.name) — \($0)" } ?? row.name)
    }
}

struct VersionCell: View {
    var row: InstalledRow

    var body: some View {
        HStack(spacing: 4) {
            Text(row.version.isEmpty ? "—" : row.version)
                .foregroundStyle(row.availableVersion == nil ? .primary : .secondary)
            if let available = row.availableVersion {
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Text(available).foregroundStyle(.tint)
            }
            if let build = row.buildText {
                Text(build).font(.caption).foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .help((row.availableVersion.map { "\(row.version) → \($0)" } ?? row.version) + (row.buildText.map { " (\($0))" } ?? ""))
    }
}

struct StatusCell: View {
    var row: InstalledRow
    var flavor: Flavor

    var body: some View {
        Group {
            switch row.condition {
            case .missingFolders:
                Label("Missing files", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Missing \(row.missingFolders.joined(separator: ", "))")
            case .missingDependencies:
                Label(row.dependencyText ?? "Needs add-ons", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(row.dependencyHelp ?? "")
            case .updateAvailable:
                Label("Update", systemImage: "arrow.down.circle.fill").foregroundStyle(.tint)
                    .help("\(row.availableVersion ?? "An update") is available")
            case .failed:
                Label("Check failed", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .help(row.failure ?? "The update check failed")
            case .noCompatibleRelease:
                Label("No \(flavor.displayName) build", systemImage: "nosign").foregroundStyle(.orange)
            case .pinned:
                Label("Pinned", systemImage: "pin.fill").foregroundStyle(.secondary)
                    .help("Pinned add-ons are never updated automatically")
            case .upToDate:
                Label("Up to date", systemImage: "checkmark").foregroundStyle(.green)
            case .unchecked:
                Text("—").foregroundStyle(.tertiary).help("Not checked yet")
            case .unmanaged:
                if row.isNotLoaded {
                    Label("Not loaded by \(flavor.displayName)", systemImage: "nosign").foregroundStyle(.orange)
                        .help("None of this folder's TOC files is for \(flavor.displayName), so the game skips it")
                } else {
                    Label("Unmanaged", systemImage: "questionmark.folder").foregroundStyle(.secondary)
                        .help("Reload didn't install this folder and won't update it")
                }
            }
        }
        .lineLimit(1)
    }
}

struct ChannelCell: View {
    var row: InstalledRow

    var body: some View {
        Text(row.channel?.title ?? "—").foregroundStyle(.secondary).lineLimit(1)
    }
}

struct InstalledDateCell: View {
    var row: InstalledRow

    var body: some View {
        Text(row.installedText).foregroundStyle(.secondary).lineLimit(1)
    }
}

struct InstalledActionCell: View {
    var queue: UpdateQueue
    var row: InstalledRow
    var rowState: RowState
    /// Opens the Adopt sheet for an unmanaged row.
    var adopt: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let error = rowState.error {
                RowErrorIcon(message: error)
            }
            if let activity = rowState.activity {
                ActivityIndicator(activity: activity, showsLabel: false)
            } else if let ref = row.ref {
                if row.availableVersion != nil {
                    Button(rowState.error == nil ? "Update" : "Retry") {
                        Task { await queue.update([ref]) }
                    }
                    .disabled(queue.isUpdatingAll)
                }
            } else {
                Button("Adopt…", action: adopt)
                    .help("Start managing this folder from its GitHub repository")
            }
        }
        // Table cells otherwise draw buttons borderless, which reads as plain text.
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Hosted in an AppKit menu, so it takes everything as properties rather than from the environment.
private struct InstalledContextMenu: View {
    var model: AppModel
    var installed: InstalledModel
    var queue: UpdateQueue
    var inspector: InspectorModel
    var status: AddonStatus
    var openWindow: OpenWindowAction

    var body: some View {
        if case .managed(let addon, let missing) = status, !missing.isEmpty {
            let allGone = Set(missing) == Set(addon.folders)
            Button("Repair") { Task { await queue.repair(addon.id) } }
            if let url = addon.id.webURL {
                Link("Open on \(addon.id.sourceName)", destination: url)
            }
            if !allGone { Button("Show in Finder") { showInFinder(addon.folders.filter { !missing.contains($0) }) } }
            Divider()
            if allGone {
                Button("Remove…", role: .destructive) { model.pendingRemoval = .forget(addon) }
            } else {
                Button("Uninstall…", role: .destructive) { model.requestUninstall(addon) }
            }
        } else if case .managed(let addon, _) = status {
            if installed.availableRelease(for: addon.id) != nil, !addon.pinned {
                Button("Update") { Task { await queue.update([addon.id]) } }
            }
            Button(addon.pinned ? "Unpin" : "Pin") {
                Task { await queue.setPinned(!addon.pinned, for: addon.id) }
            }
            if let url = addon.id.webURL {
                Link("Open on \(addon.id.sourceName)", destination: url)
            }
            Button("Show in Finder") { showInFinder(addon.folders) }
            Divider()
            Button("Uninstall…", role: .destructive) { model.requestUninstall(addon) }
        } else if let unmanaged = status.unmanagedFolder {
            Button("Adopt…") { model.adoptTarget = AdoptTarget(unmanaged) }
            Button("Show in Finder") { showInFinder(unmanaged.folders) }
            Divider()
            Button("Move to Trash…", role: .destructive) { model.pendingRemoval = .unmanaged(unmanaged) }
        }
        Divider()
        Button("Show Details") {
            inspector.selectedAddonID = status.id
            model.showInspector = true
        }
        if case .managed(let addon, _) = status {
            Button("Open in New Window") {
                openWindow(id: AddonWindowID.sceneID, value: AddonWindowID(ref: addon.id, installationID: installed.installation.id))
            }
        }
    }

    private func showInFinder(_ folders: [String]) {
        let urls = folders.map { installed.installation.addonsDirectory.appending(path: $0, directoryHint: .isDirectory) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
