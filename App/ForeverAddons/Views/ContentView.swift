import AddonKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            if let state = model.current {
                DetailView(model: model, state: state)
            } else if model.isLoadingInstallations {
                ProgressView()
            } else {
                NoInstallationView(model: model)
            }
        }
        .sheet(item: $model.adoptTarget) { target in
            if let state = model.current {
                AdoptSheet(target: target, state: state)
            }
        }
        .sheet(isPresented: $model.isSeedingPresented, onDismiss: model.seedingSheetDidClose) {
            if let state = model.seeding {
                SeedingSheet(model: model, state: state)
            }
        }
        .sheet(isPresented: Bindable(model.commandLineTool).isOfferPresented) {
            CommandLineToolOfferSheet(model: model)
        }
        .task {
            await model.initialLoad()
        }
    }
}

/// First launch, or nothing detected: explain how to point the app at the game folder.
private struct NoInstallationView: View {
    var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("No Installation Found", systemImage: "folder.badge.questionmark")
        } description: {
            Text("""
                ForeverAddons couldn't find World of Warcraft Forever. Choose its game folder, \
                usually “/Applications/World of Warcraft/_classic_beta_”, to manage its add-ons. \
                If you've just installed the game, scan again.
                """)
        } actions: {
            Button("Add Installation…") { model.addInstallationWithPanel() }
                .buttonStyle(.borderedProminent)
            Button {
                Task { await model.scanAgain() }
            } label: {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Scan Again")
                }
            }
            .disabled(model.isScanning)
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
        }
    }
}

private struct SidebarView: View {
    var model: AppModel

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
            VStack(alignment: .leading, spacing: 8) {
                Button("Add Installation…", systemImage: "plus") { model.addInstallationWithPanel() }
                    .buttonStyle(.borderless)
                if let refresh = model.visibleRefresh {
                    RefreshStatusView(progress: refresh.progress, installation: refresh.installation,
                                      showsInstallation: model.installations.count > 1)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .animation(.default, value: model.visibleRefresh == nil)
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

/// Installed / Browse tabs with the shared search field, and the inspector beside them.
///
/// The inspector is part of the detail column's content rather than an `.inspector`, so the
/// window toolbar (tabs, search, buttons) spans the whole detail area and the inspector
/// starts below it instead of growing its own toolbar section.
private struct DetailView: View {
    var model: AppModel
    @AppStorage("inspectorWidth") private var inspectorWidth = 340.0
    var state: InstallationModel

    var body: some View {
        @Bindable var model = model
        InspectorSplit(isPresented: model.showInspector, width: $inspectorWidth) {
            Group {
                switch model.tab {
                case .installed: InstalledView(model: model, state: state)
                case .browse: BrowseView(model: model, state: state)
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
        } inspector: {
            InspectorPane(model: model, state: state)
        }
        .searchable(
            text: $model.searchText, placement: .toolbar,
            prompt: model.tab == .installed ? "Filter installed add-ons" : "Search add-ons")
        .navigationTitle(state.installation.displayName)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.tab) {
                    ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.tab == .installed {
                    Button {
                        model.checkForUpdates()
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                    }
                    .help("Check for Updates (⌘R)")
                    .disabled(state.isRefreshing)

                    Button {
                        model.updateAll()
                    } label: {
                        Label(state.updateCount > 0 ? "Update All (\(state.updateCount))" : "Update All",
                              systemImage: "square.and.arrow.down.on.square")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Update every add-on that has an update and isn't pinned")
                    .disabled(state.updateCount == 0 || state.isUpdatingAll)
                }
                Button("Inspector", systemImage: "sidebar.right") {
                    withAnimation { model.showInspector.toggle() }
                }
                .help(model.showInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)")
            }
        }
        .task(id: state.installation.id) {
            // Local only: refreshes run on launch, activation and ⌘R, never on a switch.
            if !state.hasLoaded { await state.reload() }
        }
    }

    private var subtitle: String {
        guard model.tab == .installed else { return "" }
        if state.isRefreshing { return "Checking for updates…" }
        guard let checked = state.lastChecked else { return "\(state.managed.count) managed" }
        let updates = state.updateCount
        let summary = updates == 0 ? "Up to date" : updates == 1 ? "1 update" : "\(updates) updates"
        return "\(summary) · checked \(checked.formatted(.relative(presentation: .named)))"
    }
}

/// Content with a resizable trailing pane. A hand-rolled split (not `HSplitView`) so the
/// pane's width is predictable and remembered, and it can slide in and out.
private struct InspectorSplit<Content: View, Inspector: View>: View {
    var isPresented: Bool
    @Binding var width: Double
    @ViewBuilder var content: Content
    @ViewBuilder var inspector: Inspector

    @State private var dragStartWidth: Double?
    private static var widthRange: ClosedRange<Double> { 280...560 }

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(minWidth: 420, maxWidth: .infinity)
            if isPresented {
                Divider()
                    .overlay {
                        Color.clear
                            .frame(width: 9)
                            .contentShape(Rectangle())
                            .pointerStyle(.columnResize)
                            .gesture(resize)
                    }
                inspector
                    .frame(width: width.clamped(to: Self.widthRange))
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartWidth ?? width
                dragStartWidth = start
                width = (start - value.translation.width).clamped(to: Self.widthRange)
            }
            .onEnded { _ in dragStartWidth = nil }
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
