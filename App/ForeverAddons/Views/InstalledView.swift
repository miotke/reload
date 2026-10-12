import AddonKit
import AppKit
import SwiftUI

/// Managed add-ons with update status, plus unmanaged folders that can be adopted (docs/design.md §8).
/// A sortable table; managed and unmanaged rows are sorted within their own sections.
struct InstalledView: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var state: InstallationModel

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
        @Bindable var model = model
        Table(of: InstalledRow.self, selection: $model.selectedAddonID, sortOrder: sortOrder,
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
                Text(row.channel?.title ?? "—").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 80, max: 110)
            .customizationID("channel")

            TableColumn("Status", sortUsing: ColumnSort(InstalledColumn.status)) { row in
                StatusCell(row: row)
            }
            .width(min: 90, ideal: 130, max: 180)
            .customizationID("status")

            TableColumn("Installed", sortUsing: ColumnSort(InstalledColumn.installed, order: .reverse)) { row in
                Text(row.installedText).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 96, max: 130)
            .customizationID("installed")

            TableColumn("") { row in
                InstalledActionCell(model: model, state: state, row: row, rowState: state.row(row.id))
            }
            .width(min: 84, ideal: 100, max: 160)
            .customizationID("action")
            .disabledCustomizationBehavior(.visibility)
        } rows: {
            if !state.managedRows.isEmpty {
                Section("Managed") {
                    ForEach(state.managedRows) { TableRow($0) }
                }
            }
            if !state.unmanagedRows.isEmpty {
                Section("Unmanaged") {
                    ForEach(state.unmanagedRows) { TableRow($0) }
                }
            }
        }
        .contextMenu(forSelectionType: AddonStatus.ID.self) { ids in
            if let id = ids.first, let status = state.status(id: id) {
                InstalledContextMenu(model: model, state: state, status: status, openWindow: openWindow)
            }
        } primaryAction: { ids in
            // Double-click or Return. Unmanaged folders have no details to open.
            guard let id = ids.first else { return }
            if let ref = AddonRef(rowID: id), state.addon(for: ref) != nil {
                openWindow(id: AddonWindowID.sceneID, value: AddonWindowID(ref: ref, installationID: state.installation.id))
            } else {
                model.selectedAddonID = id
                model.showInspector = true
            }
        }
        .overlay { emptyState }
        .onChange(of: options, initial: true) { state.installedOptions = options }
    }

    @ViewBuilder private var emptyState: some View {
        if state.addons.isEmpty {
            if state.isLoading || !state.hasLoaded {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("No Add-ons", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Nothing is installed in \(state.installation.addonsDirectory.path(percentEncoded: false)) yet.")
                } actions: {
                    Button("Browse Add-ons") { model.tab = .browse }
                }
            }
        } else if state.managedRows.isEmpty && state.unmanagedRows.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }
}

// MARK: - Cells

private struct InstalledNameCell: View {
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

private struct VersionCell: View {
    var row: InstalledRow

    var body: some View {
        HStack(spacing: 4) {
            Text(row.version.isEmpty ? "—" : row.version)
                .foregroundStyle(row.availableVersion == nil ? .primary : .secondary)
            if let available = row.availableVersion {
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Text(available).foregroundStyle(.tint)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .help(row.availableVersion.map { "\(row.version) → \($0)" } ?? row.version)
    }
}

private struct StatusCell: View {
    var row: InstalledRow

    var body: some View {
        Group {
            switch row.condition {
            case .missingFolders:
                Label("Missing files", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Missing \(row.missingFolders.joined(separator: ", "))")
            case .updateAvailable:
                Label("Update", systemImage: "arrow.down.circle.fill").foregroundStyle(.tint)
                    .help("Version \(row.availableVersion ?? "") is available")
            case .failed:
                Label("Check failed", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .help(row.failure ?? "The update check failed")
            case .noCompatibleRelease:
                Label("No Forever build", systemImage: "nosign").foregroundStyle(.orange)
            case .pinned:
                Label("Pinned", systemImage: "pin.fill").foregroundStyle(.secondary)
                    .help("Pinned add-ons are never updated automatically")
            case .upToDate:
                Label("Up to date", systemImage: "checkmark").foregroundStyle(.green)
            case .unchecked:
                Text("—").foregroundStyle(.tertiary).help("Not checked yet")
            case .unmanaged:
                Label("Unmanaged", systemImage: "questionmark.folder").foregroundStyle(.secondary)
                    .help("ForeverAddons didn't install this folder and won't update it")
            }
        }
        .lineLimit(1)
    }
}

private struct InstalledActionCell: View {
    var model: AppModel
    var state: InstallationModel
    var row: InstalledRow
    var rowState: RowState

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
                        Task { await state.update([ref]) }
                    }
                    .disabled(state.isUpdatingAll)
                }
            } else {
                Button("Adopt…") { model.adoptTarget = state.status(id: row.id).flatMap(AdoptTarget.init) }
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
    var state: InstallationModel
    var status: AddonStatus
    var openWindow: OpenWindowAction

    var body: some View {
        if case .managed(let addon, _) = status {
            if state.availableRelease(for: addon.id) != nil, !addon.pinned {
                Button("Update") { Task { await state.update([addon.id]) } }
            }
            Button(addon.pinned ? "Unpin" : "Pin") {
                Task { await state.setPinned(!addon.pinned, for: addon.id) }
            }
            if let url = addon.id.webURL {
                Link("Open on \(addon.id.sourceName)", destination: url)
            }
            Button("Show in Finder") {
                let urls = addon.folders.map { state.installation.addonsDirectory.appending(path: $0, directoryHint: .isDirectory) }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        } else {
            Button("Adopt…") { model.adoptTarget = AdoptTarget(status) }
        }
        Divider()
        Button("Show Details") {
            model.selectedAddonID = status.id
            model.showInspector = true
        }
        if case .managed(let addon, _) = status {
            Button("Open in New Window") {
                openWindow(id: AddonWindowID.sceneID, value: AddonWindowID(ref: addon.id, installationID: state.installation.id))
            }
        }
    }
}
