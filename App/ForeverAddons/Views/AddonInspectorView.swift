import AppKit
import AddonKit
import SwiftUI

/// Details for the selected add-on: versions, changelog, folders, channel, pin, rollback, uninstall.
struct AddonInspectorView: View {
    var state: InstallationModel
    var statusID: AddonStatus.ID?

    var body: some View {
        switch state.status(id: statusID) {
        case .managed(let addon, let missing):
            ManagedInspector(state: state, addon: addon, missingFolders: missing)
        case .unmanaged(let folder, let toc, let suggested):
            UnmanagedInspector(state: state, folder: folder, toc: toc, suggestedRef: suggested)
        case nil:
            ContentUnavailableView("No Selection", systemImage: "puzzlepiece.extension",
                                   description: Text("Select an installed add-on to see its details."))
        }
    }
}

private struct ManagedInspector: View {
    var state: InstallationModel
    var addon: InstalledAddon
    var missingFolders: [String]

    @State private var confirmUninstall = false
    @State private var confirmRollback = false

    private var id: String { addon.id.description }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let error = state.rowErrors[id] { RowErrorText(message: error) }
                if let activity = state.activity[id] { ActivityIndicator(activity: activity) }
                details
                folders
                changelog
                actions
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(addon.name).font(.title2.weight(.semibold))
            if let url = addon.id.webURL {
                Link(addon.id.identifier, destination: url).font(.callout)
            } else {
                Text(addon.id.identifier).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Version").foregroundStyle(.secondary)
                Text(addon.version).monospacedDigit().textSelection(.enabled)
            }
            if let release = state.availableRelease(for: addon.id) {
                GridRow {
                    Text("Available").foregroundStyle(.secondary)
                    Text(release.version).monospacedDigit().foregroundStyle(.tint)
                }
            }
            GridRow {
                Text("Released").foregroundStyle(.secondary)
                Text(addon.publishedAt.formatted(date: .abbreviated, time: .omitted))
            }
            GridRow {
                Text("Installed").foregroundStyle(.secondary)
                Text(addon.installedAt.formatted(.relative(presentation: .named)))
            }
            GridRow {
                Text("Source").foregroundStyle(.secondary)
                Text(addon.id.sourceName)
            }
            GridRow {
                Text("Channel").foregroundStyle(.secondary)
                Picker("Channel", selection: Binding(
                    get: { addon.channel },
                    set: { channel in Task { await state.setChannel(channel, for: addon.id) } }
                )) {
                    ForEach(Channel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("Pinned").foregroundStyle(.secondary)
                Toggle("Never update automatically", isOn: Binding(
                    get: { addon.pinned },
                    set: { pinned in Task { await state.setPinned(pinned, for: addon.id) } }
                ))
                .toggleStyle(.checkbox)
            }
        }
        .font(.callout)
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Folders").font(.headline)
            ForEach(addon.folders, id: \.self) { folder in
                let missing = missingFolders.contains(folder)
                Label(folder, systemImage: missing ? "exclamationmark.triangle" : "folder")
                    .foregroundStyle(missing ? .orange : .primary)
                    .help(missing ? "This folder is missing from disk" : "")
            }
            .font(.callout)
            Button("Show in Finder", systemImage: "folder") {
                let urls = addon.folders.map { state.installation.addonsDirectory.appending(path: $0, directoryHint: .isDirectory) }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    /// Release notes from the store (installed release) and, when there's an update, the
    /// update check's release. No network request is needed.
    @ViewBuilder private var changelog: some View {
        if let release = state.availableRelease(for: addon.id) {
            notes(title: "What's New in \(release.version)", markdown: release.changelog, version: release.version)
        }
        notes(title: state.availableRelease(for: addon.id) == nil ? "Changelog" : "Installed (\(addon.version))",
              markdown: addon.changelog, version: addon.version)
    }

    private func notes(title: String, markdown: String?, version: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let markdown, !markdown.isEmpty {
                MarkdownText(markdown: markdown).font(.callout)
            } else {
                Text("No release notes for \(version).").foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    private var actions: some View {
        HStack {
            if state.availableRelease(for: addon.id) != nil {
                Button("Update") { Task { await state.update([addon.id]) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.activity[id] != nil)
            }
            if let previous = addon.previousRelease {
                Button("Roll Back to \(previous.version)…") { confirmRollback = true }
                    .disabled(state.activity[id] != nil)
                    .confirmationDialog("Roll back \(addon.name) to \(previous.version)?", isPresented: $confirmRollback) {
                        Button("Roll Back") { Task { await state.rollback(addon.id) } }
                    } message: {
                        Text("Reinstalls \(previous.version) from the local download cache and pins \(addon.name) so it isn't updated again automatically.")
                    }
            } else {
                Button("Roll Back…") {}
                    .disabled(true)
                    .help("No earlier version is cached. Rollback becomes available after an update.")
            }
            Spacer()
            Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                .disabled(state.activity[id] != nil)
                .confirmationDialog("Uninstall \(addon.name)?", isPresented: $confirmUninstall) {
                    Button("Uninstall", role: .destructive) { Task { await state.uninstall(addon.id) } }
                } message: {
                    Text("Removes \(addon.folders.joined(separator: ", ")) from Interface/AddOns. Saved settings are kept.")
                }
        }
    }
}

private struct UnmanagedInspector: View {
    @Environment(AppModel.self) private var model
    var state: InstallationModel
    var folder: String
    var toc: Toc?
    var suggestedRef: AddonRef?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(toc?.title ?? folder).font(.title2.weight(.semibold))
                    Text("Unmanaged folder").font(.callout).foregroundStyle(.secondary)
                }
                if let error = state.rowErrors["unmanaged:\(folder)"] { RowErrorText(message: error) }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    row("Folder", folder)
                    if let version = toc?.version { row("Version", version) }
                    if let author = toc?.author { row("Author", author) }
                    if let interfaces = toc?.interfaces, !interfaces.isEmpty {
                        row("Interface", interfaces.map(String.init).joined(separator: ", "))
                    }
                    if let toc {
                        row("Forever", toc.supports(state.installation.flavor) ? "Supported by TOC" : "Not listed in TOC")
                    }
                    if let suggestedRef { row("Suggested", suggestedRef.identifier) }
                }
                .font(.callout)
                if let notes = toc?.notes {
                    Text(notes).font(.callout).foregroundStyle(.secondary)
                }
                Text("ForeverAddons didn't install this folder, so it won't update it. Adopt it to manage it from its GitHub repository.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Adopt…") {
                    model.adoptTarget = AdoptTarget(.unmanaged(folder: folder, toc: toc, suggestedRef: suggestedRef))
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

#Preview {
    PreviewHost(configure: { $0.selectedAddonID = "github:BigWigsMods/BigWigs" }) { model, state in
        AddonInspectorView(state: state, statusID: model.selectedAddonID)
    }
    .frame(width: 320, height: 640)
}
