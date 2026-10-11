import AddonKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.checkForUpdatesOnLaunch) private var checkForUpdatesOnLaunch = true

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            if let state = model.current {
                DetailView(state: state)
            } else if model.isLoadingInstallations {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("No Installation", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Add your World of Warcraft Forever folder, such as “_classic_beta_”, to manage its add-ons.")
                } actions: {
                    Button("Add Installation…") { model.addInstallationWithPanel() }
                }
            }
        }
        .sheet(item: $model.adoptTarget) { target in
            if let state = model.current {
                AdoptSheet(target: target, state: state)
            }
        }
        .task { await model.initialLoad(checkForUpdates: checkForUpdatesOnLaunch) }
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedInstallationID) {
            Section("Installations") {
                ForEach(model.installations) { installation in
                    InstallationRow(installation: installation, state: model.model(for: installation))
                        .tag(installation.id)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Add Installation…", systemImage: "plus") { model.addInstallationWithPanel() }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }
}

private struct InstallationRow: View {
    var installation: Installation
    var state: InstallationModel

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(installation.displayName)
                Text(installation.gameVersion ?? installation.root.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "gamecontroller")
        }
        .badge(state.updateCount)
        .help(installation.root.path(percentEncoded: false))
    }
}

/// Installed / Browse tabs with the shared search field and the inspector.
private struct DetailView: View {
    @Environment(AppModel.self) private var model
    var state: InstallationModel

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.tab {
            case .installed: InstalledView(state: state)
            case .browse: BrowseView(state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
                    .task(id: banner.id) {
                        try? await Task.sleep(for: .seconds(8))
                        if model.banner?.id == banner.id { model.banner = nil }
                    }
            }
        }
        .animation(.default, value: model.banner)
        .searchable(
            text: $model.searchText, placement: .toolbar,
            prompt: model.tab == .installed ? "Filter installed add-ons" : "Search add-ons")
        .navigationTitle(state.installation.displayName)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.tab) {
                    ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .inspector(isPresented: $model.showInspector) {
            AddonInspectorView(state: state, statusID: model.selectedAddonID)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                .toolbar {
                    Spacer()
                    Button("Inspector", systemImage: "sidebar.right") { model.showInspector.toggle() }
                        .help("Show or hide the inspector")
                }
        }
        .task(id: state.installation.id) {
            if !state.hasLoaded { await state.reload() }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel(manager: MockAddonManager(latency: 0.3)))
        .frame(width: 1100, height: 600)
}
