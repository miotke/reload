import AddonKit
import AppKit
import SwiftUI

/// Managed add-ons with update status, plus unmanaged folders that can be adopted (docs/app/layout.md).
/// A sortable table; managed and unmanaged rows are sorted within their own sections.
struct InstalledView: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var installed: InstalledModel
    var queue: UpdateQueue
    var inspector: InspectorModel

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

    private var query: String { model.searchText.trimmingCharacters(in: .whitespaces) }

    /// Filtering and sorting happen in the model, once per change, not in `body`.
    private var options: InstalledOptions { InstalledOptions(query: query, sort: sort) }

    var body: some View {
        @Bindable var inspector = inspector
        Table(of: InstalledRow.self, selection: $inspector.selectedAddonID, sortOrder: sortOrder,
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
            if !installed.managedRows.isEmpty {
                Section("Managed") {
                    ForEach(installed.managedRows) { TableRow($0) }
                }
            }
            if !installed.unmanagedRows.isEmpty {
                Section("Unmanaged") {
                    ForEach(installed.unmanagedRows) { TableRow($0) }
                }
            }
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
        .overlay { emptyState }
        .onChange(of: options, initial: true) { installed.options = options }
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
                    Button("Browse Add-ons") { model.tab = .browse }
                }
            }
        } else if installed.managedRows.isEmpty && installed.unmanagedRows.isEmpty {
            ContentUnavailableView.search(text: query)
        }
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
                        .help("ForeverAddons didn't install this folder and won't update it")
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
        if case .managed(let addon, _) = status {
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
            Button("Uninstall…", role: .destructive) { model.pendingRemoval = .managed(addon) }
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
