import AddonKit
import AppKit
import SwiftUI

/// The inspector for an unmanaged folder or group: what the game loads from it, the suggested
/// repository and why, Adopt and Move to Trash, and the suggestion's catalogue details
/// (`details(for:in:)`, no API quota) (docs/app/layout.md).
struct UnmanagedInspector: View {
    var queue: UpdateQueue
    var inspector: InspectorModel
    var unmanaged: UnmanagedFolder
    /// Open the Adopt sheet and the Move to Trash confirmation, both hosted by the window.
    var adopt: () -> Void
    var moveToTrash: () -> Void

    private var flavor: Flavor { inspector.installation.flavor }
    private var toc: Toc? { unmanaged.toc }
    private var suggestion: AdoptionCandidate? { unmanaged.suggestion }

    var body: some View {
        let rowState = queue.row(AddonStatus.unmanagedID(unmanaged.folder))
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(unmanaged.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(unmanaged.isGroup ? "Unmanaged · \(unmanaged.folders.count) folders" : "Unmanaged folder")
                        .font(.callout).foregroundStyle(.secondary)
                }
                RowProgress(rowState: rowState)
                HStack {
                    Button("Adopt…", action: adopt)
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("Show in Finder", systemImage: "folder") {
                        let urls = unmanaged.folders.map { inspector.installation.addonsDirectory.appending(path: $0, directoryHint: .isDirectory) }
                        NSWorkspace.shared.activateFileViewerSelecting(urls)
                    }
                    Button("Move to Trash…", role: .destructive, action: moveToTrash)
                }
                .disabled(rowState.activity != nil)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    row(unmanaged.isGroup ? "Folders" : "Folder", unmanaged.folders.joined(separator: ", "))
                    if let version = unmanaged.version { row("Version", version) }
                    if let author = toc?.author { row("Author", author) }
                    if let interfaces = toc?.interfaces, !interfaces.isEmpty {
                        row("Interface", interfaces.map(String.init).joined(separator: ", "))
                    }
                    if let file = unmanaged.tocFile { row("TOC", file) }
                    GridRow {
                        Text(flavor.displayName).foregroundStyle(.secondary)
                        if unmanaged.supportsFlavor {
                            Text("Loaded by \(flavor.displayName)")
                        } else {
                            Label("Not loaded by \(flavor.displayName)", systemImage: "nosign").foregroundStyle(.orange)
                        }
                    }
                }
                .font(.callout)
                if let notes = toc?.notes, !notes.isEmpty {
                    Text(notes).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                suggestionSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The suggestion's README and screenshots, debounced like the add-on inspector.
        .task(id: suggestion?.ref) {
            guard let ref = suggestion?.ref else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await inspector.loadDetails(for: ref)
        }
    }

    @ViewBuilder private var suggestionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Suggested Repository").font(.headline)
            if let suggestion {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.ref.identifier).font(.callout.weight(.medium)).textSelection(.enabled)
                    Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                    if unmanaged.isAmbiguous {
                        Text("\(unmanaged.candidates.count) repositories match equally well; pick one when adopting.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                details(for: suggestion.ref)
            } else {
                Text("Nothing in the TOC files or the catalogue points to a repository. Adopt lets you enter one or search GitHub.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Reload didn't install \(unmanaged.isGroup ? "these folders" : "this folder"), so it won't update \(unmanaged.isGroup ? "them" : "it"). Adopt to manage \(unmanaged.isGroup ? "them" : "it") from its GitHub repository.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func details(for ref: AddonRef) -> some View {
        switch inspector.details[ref] {
        case .loaded(let details, let readme)?:
            if let summary = details.summary {
                Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                GameBubbles(model: GameBubblesModel(availableFlavors: details.availableFlavors, flavor: flavor))
                if let latest = details.latestVersion { Text("Latest \(latest)").font(.callout).foregroundStyle(.secondary) }
                Link(ref.sourceName, destination: details.repositoryURL).font(.callout)
            }
            let screenshots = Array(details.screenshots.prefix(ScreenshotLoader.maxImagesPerAddon))
            if !screenshots.isEmpty { ScreenshotGallery(urls: screenshots) }
            if !readme.isEmpty {
                Text("Read Me").font(.subheadline.weight(.semibold))
                MarkdownView(blocks: readme).font(.callout)
            }
        case .failed(let message)?:
            RowErrorText(message: "Couldn't load details: \(message)")
        case .loading?, nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading details…").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
