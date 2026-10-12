import AddonKit
import SwiftUI

/// What an add-on window shows. Opening the same value again focuses the existing window.
struct AddonWindowID: Codable, Hashable {
    static let sceneID = "addon"

    var ref: AddonRef
    var installationID: Installation.ID
}

/// An add-on's details at full size, opened by double-clicking (or Return on) a table row.
struct AddonWindow: View {
    var model: AppModel
    var id: AddonWindowID?

    private var installation: Installation? {
        model.installations.first { $0.id == id?.installationID }
    }

    var body: some View {
        Group {
            if let id, let installation {
                let state = model.model(for: installation)
                let missing: [String] = if case .managed(_, let missing)? = state.installed.status(id: id.ref.description) { missing } else { [] }
                let details = AddonDetailView(state: state, ref: id.ref, missingFolders: missing, style: .window)
                details
                    .navigationTitle(details.name)
                    .navigationSubtitle(installation.displayName)
                    .task(id: installation.id) {
                        // The Installed table may never have loaded this installation.
                        if !state.installed.hasLoaded { await state.installed.reload() }
                    }
            } else if model.isLoadingInstallations || model.installations.isEmpty {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "Add-on Unavailable", systemImage: "puzzlepiece.extension",
                    description: Text("Its installation is no longer set up in ForeverAddons."))
            }
        }
        .frame(minWidth: 560, idealWidth: 900, maxWidth: .infinity, minHeight: 420, idealHeight: 800, maxHeight: .infinity)
        // A restored window can open before the main one has loaded anything.
        .task { await model.initialLoad() }
    }
}
