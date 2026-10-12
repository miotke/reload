import AddonKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("sidebarSelection") private var storedSection: SidebarItem = .library(.installed)

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(selection: $model.section, counts: model.current?.installed.counts ?? LibraryCounts(),
                        categories: model.categories, refresh: model.visibleRefresh,
                        showsInstallation: model.installations.count > 1,
                        fetch: model.current.map { state in
                            FetchFooter.Model(lastFetched: state.queue.lastChecked, isRefreshing: state.queue.isRefreshing,
                                              refresh: model.checkForUpdates)
                        })
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
                AdoptSheet(target: target, queue: state.queue, browse: state.browse)
            }
        }
        .confirmationDialog(
            model.pendingRemoval?.title ?? "",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            presenting: model.pendingRemoval
        ) { request in
            Button(request.confirmLabel, role: .destructive) { model.performRemoval(request) }
        } message: { request in
            Text(request.message)
        }
        .sheet(isPresented: $model.isSeedingPresented, onDismiss: model.seedingSheetDidClose) {
            if let state = model.seeding {
                SeedingSheet(refresh: state.queue.refresh, flavor: state.installation.flavor) {
                    model.isSeedingPresented = false
                }
            }
        }
        .sheet(isPresented: Bindable(model.commandLineTool).isOfferPresented) {
            CommandLineToolOfferSheet(model: model)
        }
        .onChange(of: model.section) { storedSection = model.section }
        .task {
            model.section = storedSection
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

/// The selected section's table with the shared search field, and the inspector beside them.
///
/// The inspector is part of the detail column's content rather than an `.inspector`, so the
/// window toolbar (title menu, search, buttons) spans the whole detail area and the inspector
/// starts below it instead of growing its own toolbar section.
private struct DetailView: View {
    var model: AppModel
    @AppStorage("inspectorWidth") private var inspectorWidth = 340.0
    var state: InstallationModel

    private var query: String { model.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var model = model
        let section = model.section
        InspectorSplit(isPresented: model.showInspector, width: $inspectorWidth) {
            Group {
                if let library = section.librarySection {
                    InstalledView(model: model, installed: state.installed, queue: state.queue, inspector: state.inspector,
                                  section: library, query: query)
                } else {
                    BrowseView(model: model, browse: state.browse, queue: state.queue, inspector: state.inspector,
                               query: section.browseQuery(typed: query, categories: model.categories) ?? "",
                               category: section.category(in: model.categories))
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
        .searchable(text: $model.searchText, placement: .toolbar, prompt: section.searchPrompt(categories: model.categories))
        .searchSuggestions {
            // A library section filters as you type; this, or Return, searches the catalogue.
            if section.isLibrary && !query.isEmpty {
                Button {
                    model.searchAllAddons()
                } label: {
                    Label("Search All Add-ons for “\(query)”", systemImage: "magnifyingglass")
                }
            }
        }
        .onSubmit(of: .search) {
            if section.isLibrary && !query.isEmpty { model.searchAllAddons() }
        }
        .navigationTitle(state.installation.displayName)
        .navigationSubtitle(subtitle)
        .toolbarTitleMenu {
            InstallationMenu(installations: model.installations, selectedID: model.selectedInstallationID,
                             isScanning: model.isScanning,
                             select: { model.selectedInstallationID = $0 },
                             add: model.addInstallationWithPanel,
                             scan: { Task { await model.scanAgain() } })
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if section.isLibrary {
                    Button {
                        model.checkForUpdates()
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                    }
                    .help("Check for Updates (⌘R)")
                    .disabled(state.queue.isRefreshing)

                    // The Updates section has its own Update All above the table.
                    if section != .library(.updates) {
                        Button {
                            model.updateAll()
                        } label: {
                            Label(state.installed.updateCount > 0 ? "Update All (\(state.installed.updateCount))" : "Update All",
                                  systemImage: "square.and.arrow.down.on.square")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("Update every add-on that has an update and isn't pinned")
                        .disabled(state.installed.updateCount == 0 || state.queue.isUpdatingAll)
                    }
                }
                Button("Inspector", systemImage: "sidebar.right") {
                    withAnimation { model.showInspector.toggle() }
                }
                .help(model.showInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)")
            }
        }
        .task(id: state.installation.id) {
            // Local only: refreshes run on launch, activation and ⌘R, never on a switch.
            if !state.installed.hasLoaded { await state.installed.reload() }
        }
    }

    private var subtitle: String {
        guard model.section.isLibrary else { return "" }
        if state.queue.isRefreshing { return "Checking for updates…" }
        guard let checked = state.queue.lastChecked else { return "\(state.installed.managed.count) managed" }
        let updates = state.installed.updateCount
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
