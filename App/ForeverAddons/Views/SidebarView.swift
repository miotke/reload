import AddonKit
import SwiftUI

/// The sidebar: the selected installation's library sections with their counts, Browse and the
/// categories, and the refresh progress bar (docs/app/navigation.md). Takes plain values,
/// so it never reads the app model from the environment.
struct SidebarView: View {
    @Binding var selection: SidebarItem
    var counts: LibraryCounts
    var categories: [SearchCategory]
    var refresh: (installation: Installation, progress: RefreshProgress)?
    var showsInstallation: Bool

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
            if let refresh {
                RefreshStatusView(progress: refresh.progress, installation: refresh.installation,
                                  showsInstallation: showsInstallation)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: refresh == nil)
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
