import AppKit
import AddonKit
import SwiftUI

/// The trailing pane: details for whatever is selected in the current tab.
struct InspectorPane: View {
    @Environment(AppModel.self) private var model
    var state: InstallationModel

    var body: some View {
        Group {
            switch model.tab {
            case .installed:
                switch state.status(id: model.selectedAddonID) {
                case .managed(let addon, let missing):
                    AddonInspector(state: state, ref: addon.id, missingFolders: missing)
                        .id(addon.id)
                case .unmanaged(let folder, let toc, let suggested):
                    UnmanagedInspector(state: state, folder: folder, toc: toc, suggestedRef: suggested)
                        .id(folder)
                case nil:
                    noSelection("Select an add-on to see its details.")
                }
            case .browse:
                if let id = model.selectedBrowseID, let ref = AddonRef(rowID: id) {
                    AddonInspector(state: state, ref: ref, missingFolders: [])
                        .id(ref)
                } else {
                    noSelection("Select an add-on to see its details, screenshots and read-me.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noSelection(_ message: String) -> some View {
        ContentUnavailableView("No Selection", systemImage: "puzzlepiece.extension", description: Text(message))
    }
}

/// Details for one add-on, installed or not: what Browse showed, the core's `AddonDetails`
/// (stats, links, screenshots, read-me) and, when installed, the install's own state and actions.
private struct AddonInspector: View {
    var state: InstallationModel
    var ref: AddonRef
    var missingFolders: [String]

    private var id: String { ref.description }
    private var installed: InstalledAddon? { state.addon(for: ref) }
    private var result: BrowseRow? { state.browseRow(id: id) }
    private var loaded: AddonDetails? { state.details[ref]?.details }

    var body: some View {
        let rowState = state.row(id)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                RowProgress(rowState: rowState)
                InspectorActions(state: state, ref: ref, installed: installed, rowState: rowState)
                about
                detailsStatus
                if let loaded {
                    let screenshots = Array(ScreenshotFilter.screenshots(loaded.screenshots)
                        .prefix(ScreenshotLoader.maxImagesPerAddon))
                    if !screenshots.isEmpty {
                        section("Screenshots") { ScreenshotGallery(urls: screenshots) }
                    }
                }
                if let installed {
                    installedSection(installed)
                    folders(installed)
                    installedChangelog(installed)
                } else if let loaded, let notes = loaded.latestChangelog, !notes.isEmpty {
                    section("What's New\(loaded.latestVersion.map { " in \($0)" } ?? "")") {
                        MarkdownText(markdown: notes).font(.callout)
                    }
                }
                readme
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Debounced so arrow-keying through a table doesn't fetch every row; changing the
        // selection cancels this task and with it the load.
        .task(id: ref) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await state.loadDetails(for: ref)
        }
    }

    // MARK: Header & actions

    private var name: String { installed?.name ?? result?.name ?? loaded?.name ?? ref.identifier }
    private var owner: String? { result?.owner ?? loaded?.owner }
    private var summary: String? { result?.summary ?? loaded?.summary }
    private var support: SupportStatus? { loaded?.support ?? result?.support }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 8) {
                if let owner { Text("by \(owner)").foregroundStyle(.secondary) }
                if let support { SupportBadge(status: support) }
            }
            .font(.callout)
            if let summary {
                Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: About

    @ViewBuilder private var about: some View {
        let stars = loaded?.stars ?? result?.stars
        let updated = loaded?.lastUpdated ?? result?.lastUpdated
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            if let version = loaded?.latestVersion {
                row("Latest") {
                    Text(version).monospacedDigit()
                        + Text(loaded?.latestPublishedAt.map { " · \(DayLabel.string(for: $0))" } ?? "")
                        .foregroundStyle(.secondary)
                }
            }
            if let stars {
                row("Stars") { Text(stars.formatted()).monospacedDigit() }
            }
            if let updated {
                row("Updated") { Text(DayLabel.string(for: updated)) }
            }
            if let license = loaded?.license {
                row("License") { Text(license) }
            }
            if let topics = loaded?.topics, !topics.isEmpty {
                row("Topics") { Text(topics.joined(separator: ", ")).fixedSize(horizontal: false, vertical: true) }
            }
            row("Links") {
                HStack(spacing: 12) {
                    if let url = loaded?.repositoryURL ?? ref.webURL {
                        Link(ref.sourceName, destination: url)
                    }
                    if let homepage = loaded?.homepage {
                        Link("Homepage", destination: homepage)
                    }
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var detailsStatus: some View {
        switch state.details[ref] {
        case .loading?, nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading details…").foregroundStyle(.secondary)
            }
            .font(.callout)
        case .failed(let message)?:
            VStack(alignment: .leading, spacing: 6) {
                RowErrorText(message: "Couldn't load details: \(message)")
                Button("Try Again") { Task { await state.loadDetails(for: ref, force: true) } }
                    .controlSize(.small)
            }
        case .loaded?:
            EmptyView()
        }
    }

    @ViewBuilder private var readme: some View {
        if case .loaded(let details, let blocks)? = state.details[ref], !blocks.isEmpty {
            section("Read Me") {
                MarkdownView(blocks: blocks, baseURL: details.repositoryURL.appending(path: "blob/HEAD/"))
                    .font(.callout)
            }
        }
    }

    // MARK: Installed

    private func installedSection(_ addon: InstalledAddon) -> some View {
        section("Installed") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                row("Version") { Text(addon.version).monospacedDigit().textSelection(.enabled) }
                if let release = state.availableRelease(for: ref) {
                    row("Available") { Text(release.version).monospacedDigit().foregroundStyle(.tint) }
                }
                row("Released") { Text(DayLabel.string(for: addon.publishedAt)) }
                row("Installed") { Text(DayLabel.string(for: addon.installedAt)) }
                row("Channel") {
                    Picker("Channel", selection: Binding(
                        get: { addon.channel },
                        set: { channel in Task { await state.setChannel(channel, for: ref) } }
                    )) {
                        ForEach(Channel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                row("Pinned") {
                    Toggle("Never update automatically", isOn: Binding(
                        get: { addon.pinned },
                        set: { pinned in Task { await state.setPinned(pinned, for: ref) } }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            .font(.callout)
        }
    }

    private func folders(_ addon: InstalledAddon) -> some View {
        section("Folders") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(addon.folders, id: \.self) { folder in
                    let missing = missingFolders.contains(folder)
                    Label(folder, systemImage: missing ? "exclamationmark.triangle" : "folder")
                        .foregroundStyle(missing ? .orange : .primary)
                        .help(missing ? "This folder is missing from disk" : "")
                }
                Button("Show in Finder", systemImage: "folder") {
                    let urls = addon.folders.map { state.installation.addonsDirectory.appending(path: $0, directoryHint: .isDirectory) }
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    /// Release notes from the store (installed release) and, when there's an update, the
    /// update check's release. No network request is needed.
    @ViewBuilder private func installedChangelog(_ addon: InstalledAddon) -> some View {
        if let release = state.availableRelease(for: ref) {
            notes(title: "What's New in \(release.version)", markdown: release.changelog, version: release.version)
        }
        notes(title: state.availableRelease(for: ref) == nil ? "Changelog" : "Installed (\(addon.version))",
              markdown: addon.changelog, version: addon.version)
    }

    private func notes(title: String, markdown: String?, version: String) -> some View {
        section(title) {
            if let markdown, !markdown.isEmpty {
                MarkdownText(markdown: markdown).font(.callout)
            } else {
                Text("No release notes for \(version).").foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    // MARK: Helpers

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value()
        }
    }
}

/// The row's error and progress. Separate so download ticks re-render only this.
private struct RowProgress: View {
    var rowState: RowState

    var body: some View {
        if let error = rowState.error { RowErrorText(message: error) }
        if let activity = rowState.activity { ActivityIndicator(activity: activity) }
    }
}

/// Install / Update / Roll Back / Uninstall. Separate so download ticks re-render only this.
private struct InspectorActions: View {
    @AppStorage(SettingsKey.defaultChannel) private var defaultChannel: Channel = .stable
    var state: InstallationModel
    var ref: AddonRef
    var installed: InstalledAddon?
    var rowState: RowState

    @State private var confirmUninstall = false
    @State private var confirmRollback = false

    var body: some View {
        let busy = rowState.activity != nil
        HStack {
            if let installed {
                if let release = state.availableRelease(for: ref), !installed.pinned {
                    Button("Update to \(release.version)") { Task { await state.update([ref]) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
                if let previous = installed.previousRelease {
                    Button("Roll Back…") { confirmRollback = true }
                        .disabled(busy)
                        .help("Reinstall \(previous.version)")
                        .confirmationDialog("Roll back \(installed.name) to \(previous.version)?", isPresented: $confirmRollback) {
                            Button("Roll Back") { Task { await state.rollback(ref) } }
                        } message: {
                            Text("Reinstalls \(previous.version) from the local download cache and pins \(installed.name) so it isn't updated again automatically.")
                        }
                }
                Spacer()
                Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                    .disabled(busy)
                    .confirmationDialog("Uninstall \(installed.name)?", isPresented: $confirmUninstall) {
                        Button("Uninstall", role: .destructive) { Task { await state.uninstall(ref) } }
                    } message: {
                        Text("Removes \(installed.folders.joined(separator: ", ")) from Interface/AddOns. Saved settings are kept.")
                    }
            } else if rowState.needsOverwrite {
                Button("Overwrite Existing Folder", role: .destructive) {
                    Task { await state.install(ref, channel: defaultChannel, force: true) }
                }
                .disabled(busy)
            } else {
                Button("Install") { Task { await state.install(ref, channel: defaultChannel) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
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
                RowProgress(rowState: state.row("unmanaged:\(folder)"))
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
