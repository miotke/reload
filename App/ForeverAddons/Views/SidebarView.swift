import AddonKit
import SwiftUI

/// The sidebar: the selected installation's library sections with their counts, Browse and the
/// categories, the refresh progress bar, and a footer with "Last fetched" and a refresh button
/// (docs/app/navigation.md). Takes plain values, so it never reads the app model from the environment.
struct SidebarView: View {
    @Binding var selection: SidebarItem
    var counts: LibraryCounts
    var categories: [SearchCategory]
    var refresh: (installation: Installation, progress: RefreshProgress)?
    var showsInstallation: Bool
    /// The footer's "Last fetched" date and refresh action; no footer without an installation.
    var fetch: FetchFooter.Model?

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let new = $0 { selection = new } })) {
            Section("Library") {
                ForEach(LibrarySection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        // A zero badge is hidden.
                        .badge(counts[section])
                        .tag(SidebarItem.library(section))
                }
            }
            Section("Browse") {
                Label("Browse", systemImage: "square.grid.2x2")
                    .tag(SidebarItem.browse)
                ForEach(categories) { category in
                    Label(category.title, systemImage: category.symbol)
                        .tag(SidebarItem.category(category.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if let refresh {
                    RefreshStatusView(progress: refresh.progress, installation: refresh.installation,
                                      showsInstallation: showsInstallation)
                        .transition(.opacity)
                }
                if let fetch { FetchFooter(model: fetch) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .animation(.default, value: refresh == nil)
    }
}

/// "Last fetched Today, 8:53 AM ↻" at the bottom of the sidebar.
struct FetchFooter: View {
    struct Model {
        var lastFetched: Date?
        var isRefreshing: Bool
        var refresh: () -> Void
    }

    var model: Model

    var body: some View {
        HStack(spacing: 6) {
            Text(FetchLabel.string(for: model.lastFetched))
                .lineLimit(1)
                .help("When this installation's add-on details were last refreshed")
            Spacer(minLength: 4)
            Button(action: model.refresh) {
                if model.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help("Refresh now (⌘R)")
            .accessibilityLabel("Refresh")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .controlSize(.small)
    }
}

/// The title menu's content: switch installation, add one, or scan for them again.
/// Hosted in an AppKit menu, so it takes everything as properties.
struct InstallationMenu: View {
    var installations: [Installation]
    var selectedID: Installation.ID?
    var isScanning: Bool
    var select: (Installation.ID) -> Void
    var add: () -> Void
    var scan: () -> Void

    var body: some View {
        ForEach(installations) { installation in
            Toggle(isOn: Binding(get: { installation.id == selectedID }, set: { _ in select(installation.id) })) {
                InstallationMenuLabel(installation: installation)
            }
        }
        Divider()
        Button("Add Installation…", action: add)
        Button("Scan Again", action: scan)
            .disabled(isScanning)
    }
}

/// One installation in the title menu: its name, with the game version (or folder) under it.
struct InstallationMenuLabel: View {
    var installation: Installation

    var body: some View {
        Text(installation.displayName)
        // A menu shows a second Text as the item's subtitle.
        Text(installation.gameVersion ?? installation.root.lastPathComponent)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
