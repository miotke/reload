import AddonKit
import SwiftUI

/// Search and browse add-ons (docs/design.md §7, §8).
struct BrowseView: View {
    @Environment(AppModel.self) private var model
    var state: InstallationModel

    @AppStorage("browseForeverOnly") private var foreverOnly = true
    @State private var includeLiveGitHub = false

    private struct QueryKey: Hashable {
        var text: String
        var foreverOnly: Bool
        var includeLiveGitHub: Bool
        var installationID: String
    }

    private var trimmedQuery: String { model.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if trimmedQuery.isEmpty {
                BrowseHomeList(state: state, foreverOnly: foreverOnly)
            } else {
                resultsList
            }
        }
        // `.task(id:)` cancels the previous search whenever the query changes; the sleep is the debounce.
        .task(id: QueryKey(text: trimmedQuery, foreverOnly: foreverOnly, includeLiveGitHub: includeLiveGitHub,
                           installationID: state.installation.id)) {
            let text = trimmedQuery
            guard !text.isEmpty else {
                state.clearSearch()
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await state.search(SearchQuery(text: text, flavor: state.installation.flavor,
                                           foreverOnly: foreverOnly, includeLiveGitHub: includeLiveGitHub))
        }
        .task(id: state.installation.id) {
            await state.loadBrowse()
        }
        .onChange(of: model.searchText) { includeLiveGitHub = false }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(state.browse?.categories ?? SearchAliases.categories) { category in
                        let selected = trimmedQuery.caseInsensitiveCompare(category.query) == .orderedSame
                        Button {
                            model.searchText = selected ? "" : category.query
                        } label: {
                            Label(category.title, systemImage: category.symbol)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(selected ? Color.accentColor : nil)
                        .controlSize(.small)
                    }
                }
            }
            Toggle("Forever only", isOn: $foreverOnly)
                .toggleStyle(.checkbox)
                .help("Hide add-ons verified not to support Forever. Unchecked add-ons are shown dimmed.")
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var resultsList: some View {
        let installed = state.searchResults.filter { $0.installed != nil }
        let others = state.searchResults.filter { $0.installed == nil }
        List {
            if !installed.isEmpty {
                Section("Installed") {
                    ForEach(installed) { SearchResultRow(state: state, result: $0) }
                }
            }
            Section {
                ForEach(others) { SearchResultRow(state: state, result: $0) }
            } header: {
                HStack {
                    Text("Results")
                    if state.isSearching { ProgressView().controlSize(.mini) }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Search GitHub for more results", systemImage: "magnifyingglass") {
                        includeLiveGitHub = true
                    }
                    .disabled(includeLiveGitHub)
                    .help("Runs a live GitHub search. Limited to a few searches per minute without a token.")
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .overlay {
            if state.searchResults.isEmpty {
                if state.isSearching {
                    ProgressView()
                } else {
                    ContentUnavailableView.search(text: trimmedQuery)
                }
            }
        }
    }
}

/// Empty-query state: Popular on Forever / Recently updated (docs/design.md §7.5).
private struct BrowseHomeList: View {
    var state: InstallationModel
    var foreverOnly: Bool

    var body: some View {
        let popular = visible(state.browse?.popular ?? [])
        let recent = visible(state.browse?.recent ?? [])
        List {
            if !popular.isEmpty {
                Section("Popular on Forever") {
                    ForEach(popular) { SearchResultRow(state: state, result: $0) }
                }
            }
            if !recent.isEmpty {
                Section("Recently updated") {
                    ForEach(recent) { SearchResultRow(state: state, result: $0) }
                }
            }
        }
        .overlay {
            if state.browse == nil {
                ProgressView()
            } else if popular.isEmpty && recent.isEmpty {
                ContentUnavailableView(
                    "Nothing to Browse Yet", systemImage: "magnifyingglass",
                    description: Text("Search for an add-on by name, or pick a category above."))
            }
        }
    }

    private func visible(_ results: [SearchResult]) -> [SearchResult] {
        guard foreverOnly else { return results }
        return results.filter { result in
            switch result.support {
            case .unsupported, .noReleases: false
            default: true
            }
        }
    }
}

struct SearchResultRow: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.defaultChannel) private var defaultChannel: Channel = .stable
    var state: InstallationModel
    var result: SearchResult

    private var id: String { result.id.description }

    var body: some View {
        // Drop the metadata columns, then the badge, as the window narrows, so the name column
        // never collapses (a squeezed name wraps a letter per line and blows up the row height).
        ViewThatFits(in: .horizontal) {
            row(showsBadge: true, showsMetadata: true)
            row(showsBadge: true, showsMetadata: false)
            row(showsBadge: false, showsMetadata: false)
        }
        .padding(.vertical, 3)
        .contextMenu {
            if let url = result.id.webURL {
                Link("Open on \(result.id.sourceName)", destination: url)
            }
        }
    }

    private func row(showsBadge: Bool, showsMetadata: Bool) -> some View {
        HStack(spacing: 12) {
            details
                .frame(minWidth: 200, idealWidth: 200, maxWidth: .infinity, alignment: .leading)
                .opacity(SupportBadge.isDimmed(result.support) && result.installed == nil ? 0.6 : 1)

            if showsBadge {
                SupportBadge(status: result.support)
                    .frame(width: 100, alignment: .leading)
            }

            if showsMetadata {
                metadata
            }

            action
                .frame(width: 110, alignment: .trailing)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(result.name).fontWeight(.medium).lineLimit(1).layoutPriority(1)
                Text(result.owner).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if result.origin.contains(.github) {
                    Image(systemName: "globe").font(.caption).foregroundStyle(.secondary)
                        .help("Found by live GitHub search")
                }
            }
            if let summary = result.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let error = state.rowErrors[id] {
                RowErrorText(message: error)
            }
        }
    }

    @ViewBuilder private var metadata: some View {
        if let installed = result.installed {
            Text(installed.version)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
        } else {
            Group {
                if let stars = result.stars {
                    Label("\(stars)", systemImage: "star").labelStyle(.titleAndIcon)
                } else {
                    Text("")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: 60, alignment: .leading)

            Text(result.lastUpdated?.formatted(.relative(presentation: .named)) ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
        }
    }

    @ViewBuilder private var action: some View {
        if let installed = result.installed {
            Button("Open") { model.reveal(installed.id) }
        } else if let activity = state.activity[id] {
            ActivityIndicator(activity: activity)
        } else if state.needsOverwrite.contains(result.id) {
            Button("Overwrite", role: .destructive) {
                Task { await state.install(result.id, channel: defaultChannel, force: true) }
            }
            .help("Replace the existing unmanaged folder")
        } else {
            Button("Install") {
                Task { await state.install(result.id, channel: defaultChannel) }
            }
        }
    }
}
