import AppKit
import AddonKit
import SwiftUI

/// The trailing pane: details for whatever is selected in the current section.
struct InspectorPane: View {
    var model: AppModel
    var state: InstallationModel

    var body: some View {
        Group {
            switch model.section.isLibrary {
            case true:
                switch state.installed.status(id: state.inspector.selectedAddonID) {
                case .managed(let addon, let missing):
                    AddonDetailView(state: state, ref: addon.id, missingFolders: missing)
                        .id(addon.id)
                case .unmanaged(let unmanaged):
                    UnmanagedInspector(queue: state.queue, inspector: state.inspector, unmanaged: unmanaged,
                                       adopt: { model.adoptTarget = AdoptTarget(unmanaged) },
                                       moveToTrash: { model.pendingRemoval = .unmanaged(unmanaged) })
                        .id(unmanaged.folder)
                case nil:
                    noSelection("Select an add-on to see its details.")
                }
            case false:
                if let id = state.inspector.selectedBrowseID, let ref = AddonRef(rowID: id) {
                    AddonDetailView(state: state, ref: ref, missingFolders: [])
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
/// Shown in the inspector and, full size, in an add-on's own window. It combines all four of
/// the installation's models, so it takes `InstallationModel` and reads each part directly.
struct AddonDetailView: View {
    enum Style { case inspector, window }

    var state: InstallationModel
    var ref: AddonRef
    var missingFolders: [String]
    var style: Style = .inspector

    /// The installed record's row when installed: a search result's case can differ.
    private var id: String { (installed?.id ?? ref).description }
    private var installed: InstalledAddon? { state.installed.addon(for: ref) }
    private var result: BrowseRow? { state.browse.row(id: id) }
    private var loaded: AddonDetails? { state.inspector.details[ref]?.details }

    var body: some View {
        let rowState = state.queue.row(id)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                RowProgress(rowState: rowState)
                InspectorActions(installedModel: state.installed, queue: state.queue, ref: ref, installed: installed,
                                 rowState: rowState, availableFlavors: availableFlavors, name: name)
                about
                detailsStatus
                if let loaded {
                    // The core already drops badges, SVGs and tiny icons.
                    let screenshots = Array(loaded.screenshots.prefix(ScreenshotLoader.maxImagesPerAddon))
                    if !screenshots.isEmpty {
                        section("Screenshots") {
                            switch style {
                            case .inspector: ScreenshotGallery(urls: screenshots)
                            case .window: ScreenshotGallery(urls: screenshots, thumbnail: CGSize(width: 320, height: 200))
                            }
                        }
                    }
                }
                if let installed {
                    installedSection(installed)
                    folders(installed)
                    installedChangelog(installed)
                } else if let loaded, let version = loaded.latestVersion {
                    notes(title: "What's New in \(version)", markdown: loaded.latestChangelog, version: version, loadable: true)
                }
                readme
            }
            .padding(.all, style == .window ? 24 : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Debounced so arrow-keying through a table doesn't fetch every row; changing the
        // selection cancels this task and with it the load.
        .task(id: ref) {
            if style == .inspector {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await state.inspector.loadDetails(for: ref)
        }
    }

    // MARK: Header & actions

    var name: String { installed?.name ?? result?.name ?? loaded?.name ?? ref.identifier }
    private var owner: String? { result?.owner ?? loaded?.owner }
    private var summary: String? { result?.summary ?? loaded?.summary }
    private var support: SupportStatus { loaded?.support ?? result?.support ?? .unknown }
    private var availableFlavors: Set<Flavor>? { loaded?.availableFlavors ?? result?.availableFlavors }

    private var header: some View {
        let flavor = state.installation.flavor
        return VStack(alignment: .leading, spacing: 6) {
            Text(name).font((style == .window ? Font.largeTitle : .title2).weight(.semibold)).textSelection(.enabled)
            if let owner { Text("by \(owner)").foregroundStyle(.secondary).font(.callout) }
            HStack(spacing: 8) {
                GameBubbles(model: GameBubblesModel(availableFlavors: availableFlavors, flavor: flavor, support: support))
                Text(GameAvailability.sentence(availableFlavors: availableFlavors, for: flavor))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    let published = Text(loaded?.latestPublishedAt.map { " · \(DayLabel.string(for: $0))" } ?? "")
                        .foregroundStyle(.secondary)
                    Text("\(Text(version).monospacedDigit())\(published)")
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
        switch state.inspector.details[ref] {
        case .loading?, nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading details…").foregroundStyle(.secondary)
            }
            .font(.callout)
        case .failed(let message)?:
            VStack(alignment: .leading, spacing: 6) {
                RowErrorText(message: "Couldn't load details: \(message)")
                Button("Try Again") { Task { await state.inspector.loadDetails(for: ref, force: true) } }
                    .controlSize(.small)
            }
        case .loaded?:
            EmptyView()
        }
    }

    @ViewBuilder private var readme: some View {
        if case .loaded(_, let blocks)? = state.inspector.details[ref], !blocks.isEmpty {
            section("Read Me") {
                MarkdownView(blocks: blocks).font(.callout)
            }
        }
    }

    // MARK: Installed

    private func installedSection(_ addon: InstalledAddon) -> some View {
        section("Installed") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                row("Version") { Text(addon.version).monospacedDigit().textSelection(.enabled) }
                if let build = RetailBuildOffer.buildLabel(addon) {
                    row("Build") {
                        Text(build)
                            .help("\(state.installation.flavor.displayName) lists it as out of date until you tick Load out of date AddOns")
                    }
                }
                if let release = state.installed.availableRelease(for: ref) {
                    row("Available") { Text(release.version).monospacedDigit().foregroundStyle(.tint) }
                }
                row("Released") { Text(DayLabel.string(for: addon.publishedAt)) }
                row("Installed") { Text(DayLabel.string(for: addon.installedAt)) }
                row("Channel") {
                    Picker("Channel", selection: Binding(
                        get: { addon.channel },
                        set: { channel in Task { await state.queue.setChannel(channel, for: addon.id) } }
                    )) {
                        ForEach(Channel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                row("Pinned") {
                    Toggle("Never update automatically", isOn: Binding(
                        get: { addon.pinned },
                        set: { pinned in Task { await state.queue.setPinned(pinned, for: addon.id) } }
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
    /// update check's release. A quota-free check has no notes; when the update is the
    /// latest release, they can be loaded on demand.
    @ViewBuilder private func installedChangelog(_ addon: InstalledAddon) -> some View {
        if let release = state.installed.availableRelease(for: ref) {
            let isLatest = loaded?.latestVersion == release.version
            notes(title: "What's New in \(release.version)",
                  markdown: release.changelog ?? (isLatest ? loaded?.latestChangelog : nil),
                  version: release.version, loadable: isLatest)
        }
        notes(title: state.installed.availableRelease(for: ref) == nil ? "Changelog" : "Installed (\(addon.version))",
              markdown: addon.changelog, version: addon.version)
    }

    /// `loadable`: missing notes can be fetched (`releaseNotes`, one API call).
    private func notes(title: String, markdown: String?, version: String, loadable: Bool = false) -> some View {
        section(title) {
            if let markdown, !markdown.isEmpty {
                MarkdownText(markdown: markdown).font(.callout)
            } else if markdown == nil, loadable {
                ReleaseNotesButton(inspector: state.inspector, ref: ref)
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

/// Loads the latest release's notes on request: they cost a GitHub API call, so opening an
/// add-on doesn't fetch them.
private struct ReleaseNotesButton: View {
    var inspector: InspectorModel
    var ref: AddonRef

    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Show Release Notes") { Task { await load() } }
                    .controlSize(.small)
                    .disabled(isLoading)
                    .help("Uses one GitHub API call")
                if isLoading { ProgressView().controlSize(.small) }
            }
            if let error { RowErrorText(message: error) }
        }
        .font(.callout)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await inspector.loadReleaseNotes(for: ref)
            error = nil
        } catch {
            self.error = "Couldn't load release notes: \(error.localizedDescription)"
        }
    }
}

/// The row's error and progress. Separate so download ticks re-render only this.
struct RowProgress: View {
    var rowState: RowState

    var body: some View {
        if let error = rowState.error { RowErrorText(message: error) }
        if let activity = rowState.activity { ActivityIndicator(activity: activity) }
    }
}

/// Install / Update / Roll Back / Uninstall. Separate so download ticks re-render only this.
private struct InspectorActions: View {
    @AppStorage(SettingsKey.defaultChannel) private var defaultChannel: Channel = .stable
    var installedModel: InstalledModel
    var queue: UpdateQueue
    var ref: AddonRef
    var installed: InstalledAddon?
    var rowState: RowState
    var availableFlavors: Set<Flavor>?
    var name: String

    @State private var confirmUninstall = false
    @State private var confirmRollback = false
    @State private var confirmRetailBuild = false

    var body: some View {
        let busy = rowState.activity != nil
        let action = installedModel.installAction(for: ref, availableFlavors: availableFlavors)
        let flavor = queue.installation.flavor
        HStack {
            if let installed, let installedRef = action.installedRef {
                Label("Installed \(installed.version)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                if case .update(_, _, let offer) = action {
                    Button("Update to \(offer.label)") { Task { await queue.update([installedRef]) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
                if let previous = installed.previousRelease {
                    Button("Roll Back…") { confirmRollback = true }
                        .disabled(busy)
                        .help("Reinstall \(previous.version)")
                        .confirmationDialog("Roll back \(installed.name) to \(previous.version)?", isPresented: $confirmRollback) {
                            Button("Roll Back") { Task { await queue.rollback(installedRef) } }
                        } message: {
                            Text("Reinstalls \(previous.version) from the local download cache and pins \(installed.name) so it isn't updated again automatically.")
                        }
                }
                Spacer()
                Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                    .disabled(busy)
                    .confirmationDialog("Uninstall \(installed.name)?", isPresented: $confirmUninstall) {
                        Button("Uninstall", role: .destructive) { Task { await queue.uninstall(installedRef) } }
                    } message: {
                        Text("Removes \(installed.folders.joined(separator: ", ")) from Interface/AddOns. Saved settings are kept.")
                    }
            } else if rowState.needsOverwrite {
                Button("Overwrite Existing Folder", role: .destructive) {
                    Task { await queue.install(ref, channel: defaultChannel, force: true) }
                }
                .disabled(busy)
            } else if case .installFallbackBuild = action {
                Button("Install Retail Build…") { confirmRetailBuild = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    .help("No \(flavor.displayName) build yet; the Retail build may work")
            } else {
                Button("Install") { Task { await queue.install(ref, channel: defaultChannel) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
        }
        .sheet(isPresented: $confirmRetailBuild) {
            RetailBuildSheet(name: name, flavor: queue.installation.flavor) {
                Task { await queue.install(ref, channel: defaultChannel, allowFamilyFallback: true) }
            }
        }
    }
}

/// Confirms installing the Retail build on Forever, and explains the out-of-date checkbox.
struct RetailBuildSheet: View {
    var name: String
    var flavor: Flavor
    var install: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install the Retail build of \(name)?").font(.headline)
            Text(RetailBuildOffer.explanation(for: flavor))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install Retail Build") {
                    install()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
