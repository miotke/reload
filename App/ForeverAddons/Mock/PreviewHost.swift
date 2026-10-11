import SwiftUI

/// Hosts a preview with an `AppModel` backed by `MockAddonManager`, loaded and update-checked.
struct PreviewHost<Content: View>: View {
    @State private var model = AppModel(manager: MockAddonManager(latency: 0.2))
    var configure: @MainActor (AppModel) -> Void = { _ in }
    @ViewBuilder var content: (AppModel, InstallationModel) -> Content

    var body: some View {
        Group {
            if let current = model.current {
                content(model, current)
            } else {
                ProgressView()
            }
        }
        .environment(model)
        .task {
            configure(model)
            await model.initialLoad(checkForUpdates: true)
        }
    }
}
