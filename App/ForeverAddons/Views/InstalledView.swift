import AddonKit
import SwiftUI

/// Managed add-ons with update status, plus unmanaged folders that can be adopted (docs/design.md §8).
struct InstalledView: View {
    @Environment(AppModel.self) private var model
    var state: InstallationModel

    var body: some View {
        @Bindable var model = model
        let managed = filteredManaged
        let unmanaged = filteredUnmanaged
        List(selection: $model.selectedAddonID) {
            if !managed.isEmpty {
                Section("Managed") {
                    ForEach(managed, id: \.addon.id) { item in
                        ManagedAddonRow(state: state, addon: item.addon, missingFolders: item.missing)
                            .tag(item.addon.id.description)
                    }
                }
            }
            if !unmanaged.isEmpty {
                Section("Unmanaged") {
                    ForEach(unmanaged) { status in
                        UnmanagedAddonRow(state: state, status: status)
                            .tag(status.id)
                    }
                }
            }
        }
        .overlay { emptyState }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.checkForUpdates()
                } label: {
                    if state.isCheckingForUpdates {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                    }
                }
                .help("Check for Updates (⌘R)")
                .disabled(state.isCheckingForUpdates)

                Button {
                    model.updateAll()
                } label: {
                    Label(state.updateCount > 0 ? "Update All (\(state.updateCount))" : "Update All",
                          systemImage: "square.and.arrow.down.on.square")
                        .labelStyle(.titleAndIcon)
                }
                .help("Update every add-on that has an update and isn't pinned")
                .disabled(state.updateCount == 0 || state.isUpdatingAll)
            }
        }
    }

    // MARK: Filtering

    private var query: String { model.searchText.trimmingCharacters(in: .whitespaces) }

    private var filteredManaged: [(addon: InstalledAddon, missing: [String])] {
        state.addons.compactMap { status in
            guard case .managed(let addon, let missing) = status else { return nil }
            guard query.isEmpty
                || addon.name.localizedCaseInsensitiveContains(query)
                || addon.id.identifier.localizedCaseInsensitiveContains(query)
                || addon.folders.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            else { return nil }
            return (addon, missing)
        }
    }

    private var filteredUnmanaged: [AddonStatus] {
        state.unmanaged.filter { status in
            guard !query.isEmpty, case .unmanaged(let folder, let toc, _) = status else { return true }
            return folder.localizedCaseInsensitiveContains(query) || (toc?.title?.localizedCaseInsensitiveContains(query) ?? false)
        }
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
        } else if filteredManaged.isEmpty && filteredUnmanaged.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private var subtitle: String {
        if state.isCheckingForUpdates { return "Checking for updates…" }
        guard let checked = state.lastChecked else { return "\(state.managed.count) managed" }
        let updates = state.updateCount
        let summary = updates == 0 ? "Up to date" : updates == 1 ? "1 update" : "\(updates) updates"
        return "\(summary) · checked \(checked.formatted(.relative(presentation: .named)))"
    }
}

// MARK: - Rows

private struct ManagedAddonRow: View {
    @Environment(AppModel.self) private var model
    var state: InstallationModel
    var addon: InstalledAddon
    var missingFolders: [String]

    private var id: String { addon.id.description }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(addon.name).fontWeight(.medium).lineLimit(1)
                if !missingFolders.isEmpty {
                    Label("Missing \(missingFolders.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = state.rowErrors[id] {
                    RowErrorText(message: error)
                }
            }
            // A minimum width keeps a narrow window from wrapping the name a letter per line.
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)

            versionText
                .frame(minWidth: 150, alignment: .leading)

            Text(addon.id.sourceName)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            statusColumn
                .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contextMenu { contextMenu }
    }

    @ViewBuilder private var versionText: some View {
        if let release = state.availableRelease(for: addon.id), !addon.pinned {
            HStack(spacing: 4) {
                Text(addon.version).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Text(release.version).foregroundStyle(.tint)
            }
            .monospacedDigit()
            .lineLimit(1)
        } else {
            Text(addon.version).monospacedDigit().lineLimit(1)
        }
    }

    @ViewBuilder private var statusColumn: some View {
        if let activity = state.activity[id] {
            ActivityIndicator(activity: activity)
        } else if addon.pinned {
            Label("Pinned", systemImage: "pin.fill")
                .foregroundStyle(.secondary)
                .help("Pinned add-ons are never updated automatically")
        } else {
            switch state.updateStates[addon.id] {
            case .available:
                Button(state.rowErrors[id] == nil ? "Update" : "Retry") {
                    Task { await state.update([addon.id]) }
                }
                .disabled(state.isUpdatingAll)
            case .upToDate:
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                    .help("Up to date")
                    .accessibilityLabel("Up to date")
            case .noCompatibleRelease:
                Text("No Forever build").font(.caption).foregroundStyle(.orange)
            case .failed:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
            case .pinned:
                Label("Pinned", systemImage: "pin.fill").foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var contextMenu: some View {
        if state.availableRelease(for: addon.id) != nil {
            Button("Update") { Task { await state.update([addon.id]) } }
        }
        Button(addon.pinned ? "Unpin" : "Pin") {
            Task { await state.setPinned(!addon.pinned, for: addon.id) }
        }
        if let url = addon.id.webURL {
            Link("Open on \(addon.id.sourceName)", destination: url)
        }
        Divider()
        Button("Show Details") {
            model.selectedAddonID = id
            model.showInspector = true
        }
    }
}

private struct UnmanagedAddonRow: View {
    @Environment(AppModel.self) private var model
    var state: InstallationModel
    var status: AddonStatus

    var body: some View {
        if case .unmanaged(let folder, let toc, _) = status {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder).fontWeight(.medium).lineLimit(1)
                    if let title = toc?.title, title != folder {
                        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let error = state.rowErrors[status.id] {
                        RowErrorText(message: error)
                    }
                }
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)

                Text(toc?.version ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 150, alignment: .leading)

                Text("Unmanaged")
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)

                Group {
                    if let activity = state.activity[status.id] {
                        ActivityIndicator(activity: activity)
                    } else {
                        Button("Adopt…") { model.adoptTarget = AdoptTarget(status) }
                            .help("Start managing this folder from its GitHub repository")
                    }
                }
                .frame(width: 150, alignment: .trailing)
            }
            .padding(.vertical, 3)
        }
    }
}
