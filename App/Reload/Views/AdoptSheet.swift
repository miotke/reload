import AddonKit
import SwiftUI

/// Start managing an unmanaged folder (or group) from a GitHub repository (docs/app/layout.md).
///
/// The repository is pre-filled with the best local candidate and its reason; a picker
/// offers the others. The chosen repo's release is checked before Adopt, listing the folders
/// it replaces. "Search GitHub…" is the only thing here that spends search quota.
struct AdoptSheet: View {
    @Environment(\.dismiss) private var dismiss
    var target: AdoptTarget
    var queue: UpdateQueue
    /// For the explicit GitHub search.
    var browse: BrowseModel

    @State private var repository = ""
    @State private var isAdopting = false
    /// The ref the preview is for, set by an explicit choice (pre-fill, picker, search, Return).
    @State private var previewRef: AddonRef?
    @State private var preview: AdoptionPreviewState?
    @State private var searchResults: [SearchResult]?
    @State private var isSearching = false
    @State private var confirmTrash = false

    private var unmanaged: UnmanagedFolder { target.unmanaged }
    private var flavor: Flavor { queue.installation.flavor }
    private var rowID: String { AddonStatus.unmanagedID(target.folder) }
    private var typedRef: AddonRef? { AddonRef(parsing: repository) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adopt \(unmanaged.title)").font(.title3.weight(.semibold))

            Form {
                LabeledContent(unmanaged.isGroup ? "Folders" : "Folder", value: unmanaged.folders.joined(separator: ", "))
                LabeledContent("Installed", value: [unmanaged.title, unmanaged.version].compactMap { $0 }.joined(separator: " "))
                if !unmanaged.supportsFlavor {
                    LabeledContent(flavor.displayName, value: "Not loaded by \(flavor.displayName)")
                }
                repositorySection
                releaseSection
            }
            .formStyle(.grouped)
            // A grouped form scrolls inside its ideal height, which clipped the Why and Release rows.
            .fixedSize(horizontal: false, vertical: true)

            if let searchResults { searchList(searchResults) }

            if let error = queue.row(rowID).error {
                RowErrorText(message: error)
            }

            HStack {
                Button("Move to Trash…", role: .destructive) { confirmTrash = true }
                    .disabled(isAdopting)
                if isAdopting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Adopt", action: adopt)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!AdoptForm.canAdopt(text: repository, previewed: previewRef, preview: preview, isBusy: isAdopting))
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            guard repository.isEmpty, let best = unmanaged.suggestion else { return }
            choose(best.ref)
        }
        .task(id: previewRef) {
            guard let ref = previewRef else { return }
            preview = .loading
            let result = await queue.adoptionPreview(for: ref, folders: unmanaged.folders)
            if !Task.isCancelled, previewRef == ref { preview = result }
        }
        .confirmationDialog("Move \(unmanaged.title) to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    if await queue.removeUnmanaged(unmanaged.folders, id: rowID) { dismiss() }
                }
            }
        } message: {
            Text(RemovalRequest.trashMessage(unmanaged.folders))
        }
    }

    // MARK: Repository

    @ViewBuilder private var repositorySection: some View {
        if unmanaged.candidates.count > 1 {
            let picked = typedRef.flatMap { typed in unmanaged.candidates.first { $0.ref.isSameRepo(as: typed) }?.ref }
            Picker("Suggestions", selection: Binding(get: { picked }, set: { if let ref = $0 { choose(ref) } })) {
                if picked == nil { Text("Other").tag(AddonRef?.none) }
                ForEach(unmanaged.candidates) { candidate in
                    Text("\(candidate.ref.identifier) — \(candidate.reason)").tag(Optional(candidate.ref))
                }
            }
        }
        LabeledContent("Repository") {
            HStack {
                TextField("GitHub repository", text: $repository, prompt: Text("owner/repo"))
                    .labelsHidden()
                    .onSubmit { if let ref = typedRef { choose(ref) } }
                Button("Search GitHub…") { Task { await search() } }
                    .disabled(isSearching)
                    .help("Searches GitHub live. Limited to 10 searches a minute.")
            }
        }
        if let reason = AdoptForm.reason(for: repository, candidates: unmanaged.candidates, searched: Set(searchResults?.map(\.id) ?? [])) {
            LabeledContent("Why", value: reason)
        } else if unmanaged.candidates.isEmpty, repository.isEmpty {
            Text("No repository found in the TOC files or the catalogue. Enter one, or search GitHub.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func choose(_ ref: AddonRef) {
        repository = ref.identifier
        if previewRef.map({ !$0.isSameRepo(as: ref) }) ?? true {
            preview = nil
            previewRef = ref
        }
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        searchResults = Array(await browse.searchGitHub(AdoptForm.searchText(field: repository, title: unmanaged.title)).prefix(8))
    }

    private func searchList(_ results: [SearchResult]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(results.isEmpty ? "No repositories found." : "Search results").font(.subheadline.weight(.semibold))
            ForEach(results) { result in
                Button {
                    choose(result.id)
                } label: {
                    HStack {
                        Text(result.id.identifier).fontWeight(.medium)
                        Text(result.summary ?? "").foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        GameBubbles(model: GameBubblesModel(availableFlavors: result.availableFlavors, flavor: flavor))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
    }

    // MARK: Release

    @ViewBuilder private var releaseSection: some View {
        if let ref = typedRef, previewRef.map({ !$0.isSameRepo(as: ref) }) ?? true {
            LabeledContent("Release") {
                Button("Check Release") { choose(ref) }
                    .help("Finds the latest \(flavor.displayName) release and the folders it replaces")
            }
        } else if let preview {
            switch preview {
            case .loading:
                LabeledContent("Release") {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking the latest \(flavor.displayName) release…").foregroundStyle(.secondary)
                    }
                }
            case .ready(let found):
                LabeledContent("Release", value: found.release.version)
                if !found.replaces.isEmpty {
                    LabeledContent("Replaces", value: found.replaces.joined(separator: ", "))
                }
                if !found.adds.isEmpty {
                    LabeledContent("Adds", value: found.adds.joined(separator: ", "))
                }
                ForEach(found.conflicts.keys.sorted(), id: \.self) { folder in
                    RowErrorText(message: "\(folder) is already managed as \(found.conflicts[folder]!.identifier). Uninstall that first.")
                }
                if !found.notCovered.isEmpty {
                    Text("\(found.notCovered.joined(separator: ", ")) isn't in this release and stays unmanaged.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .noBuild:
                RowErrorText(message: "This repository has no \(flavor.displayName) build in its releases.")
            case .failed(let message):
                RowErrorText(message: "Couldn't check the release: \(message)")
            }
        }
    }

    private func adopt() {
        guard let ref = typedRef, !isAdopting else { return }
        var release: ResolvedRelease?
        if case .ready(let found)? = preview, let previewRef, previewRef.isSameRepo(as: ref) { release = found.release }
        isAdopting = true
        Task {
            let succeeded = await queue.adopt(folder: target.folder, as: release?.ref ?? ref, release: release)
            isAdopting = false
            if succeeded { dismiss() }
        }
    }
}
