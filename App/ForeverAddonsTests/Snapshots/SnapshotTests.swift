import AddonKit
import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Renders key views over `Fixtures` to `build/snapshots/<name>-<light|dark>.png`, so agents
/// can look at the UI without launching the app (docs/development.md). A test passes when
/// rendering succeeds; nothing is compared. `Table` doesn't render offscreen, so table rows
/// are the real cell views laid out in a `VStack` at the column widths.
@MainActor @Suite(.serialized) struct SnapshotTests {
    let state: InstallationModel

    init() async {
        state = InstallationModel(installation: Fixtures.installation, manager: FixtureManager(), reportError: { _ in })
        await state.installed.reload()
        state.queue.apply(Fixtures.updates)
        await state.queue.loadLastRefresh()
        await state.browse.loadBrowse()
        // Release notes parse in a task the snapshot doesn't wait for; warm their cache instead.
        for markdown in Fixtures.markdownShown { _ = await MarkdownCache.blocks(for: markdown) }
    }

    // MARK: Browse

    @Test func browseRows() throws {
        let rows = Fixtures.browseResults.map { state.browse.row(for: $0, now: Fixtures.date(10, 12)) }
        try Snapshot.render("browse-rows", width: 760) {
            TableSnapshot(columns: BrowseRowSnapshot.columns) {
                ForEach(rows) { row in BrowseRowSnapshot(state: state, row: row) }
            }
        }
    }

    @Test func gamesAndStatusBar() throws {
        let cases: [(String, Set<Flavor>?, SupportStatus)] = [
            ("Forever + Retail + Classic", [.forever, .mainline, .vanilla], .supported(version: "1")),
            ("Forever only", [.forever], .supported(version: "1")),
            ("Retail only", [.mainline], .unsupported),
            ("Classic only", [.vanilla, .tbc], .unsupported),
            ("No release.json", nil, .needsDownload),
        ]
        try Snapshot.render("games", width: 760) {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(cases, id: \.0) { label, flavors, support in
                        GridRow {
                            Text(label).foregroundStyle(.secondary)
                            GameBubbles(model: GameBubblesModel(availableFlavors: flavors, flavor: .forever, support: support))
                            Text(GameAvailability.sentence(availableFlavors: flavors, for: .forever)).font(.callout)
                        }
                    }
                }
                .padding(12)
                Divider()
                BrowseStatusBar(browse: state.browse, isHome: true, hasSort: false,
                                includeLiveGitHub: .constant(false), resetSort: {})
                Divider()
                BrowseStatusBar(browse: state.browse, isHome: false, hasSort: true,
                                includeLiveGitHub: .constant(false), resetSort: {})
            }
        }
    }

    // MARK: Installed

    @Test func installedRows() throws {
        try renderSection(.installed, name: "installed-rows")
    }

    @Test func updatesSection() throws {
        try renderSection(.updates, name: "updates-section")
    }

    @Test func unmanagedSection() throws {
        try renderSection(.unmanaged, name: "unmanaged-section")
    }

    @Test func pinnedSection() throws {
        try renderSection(.pinned, name: "pinned-section")
    }

    /// A library section as `InstalledView` lays it out: the Updates header, then its rows.
    private func renderSection(_ section: LibrarySection, name: String) throws {
        state.installed.options.section = section
        try Snapshot.render(name, width: 900) {
            VStack(alignment: .leading, spacing: 0) {
                if section == .updates {
                    UpdatesHeader(count: state.installed.counts.updates, isUpdating: false, updateAll: {})
                    Divider()
                }
                TableSnapshot(columns: InstalledRowSnapshot.columns) {
                    ForEach(state.installed.rows) { row in InstalledRowSnapshot(state: state, row: row) }
                }
            }
        }
    }

    // MARK: Navigation

    @Test func sidebar() throws {
        try Snapshot.render("sidebar", width: 220, height: 480) {
            SidebarView(selection: .constant(.library(.updates)), counts: state.installed.counts,
                        categories: SearchAliases.categories, refresh: nil, showsInstallation: false,
                        fetch: FetchFooter.Model(lastFetched: Fixtures.date(10, 12), isRefreshing: false, refresh: {}))
        }
    }

    @Test func sidebarRefreshing() throws {
        let progress = RefreshProgress(phase: .updates, completed: 3, total: 8, message: "Checking for updates…")
        try Snapshot.render("sidebar-refreshing", width: 220, height: 540) {
            SidebarView(selection: .constant(.library(.installed)), counts: state.installed.counts,
                        categories: SearchAliases.categories, refresh: (Fixtures.installation, progress), showsInstallation: false,
                        fetch: FetchFooter.Model(lastFetched: Fixtures.date(10, 12), isRefreshing: true, refresh: {}))
        }
    }

    @Test func categorySelected() throws {
        let bags = try #require(SearchAliases.categories.first { $0.id == "bags" })
        let rows = [Fixtures.browseInstalled, Fixtures.browseUnchecked].map { state.browse.row(for: $0, now: Fixtures.date(10, 12)) }
        try Snapshot.render("category-selected", width: 1000, height: 480) {
            HStack(alignment: .top, spacing: 0) {
                SidebarView(selection: .constant(.category(bags.id)), counts: state.installed.counts,
                            categories: SearchAliases.categories, refresh: nil, showsInstallation: false)
                    .frame(width: 220)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    BrowseFilterBar(flavor: .forever, isHome: false, category: bags,
                                    home: .constant(.popular), hideIncompatible: .constant(true))
                    Divider()
                    TableSnapshot(columns: BrowseRowSnapshot.columns) {
                        ForEach(rows) { row in BrowseRowSnapshot(state: state, row: row) }
                    }
                }
            }
        }
    }

    @Test func installationMenu() throws {
        let classic = Installation(id: "snapshot-era", root: URL(filePath: "/tmp/ForeverAddonsSnapshots/World of Warcraft/_classic_era_"),
                                   flavor: .vanilla, gameVersion: "1.15.7.61582")
        try Snapshot.render("installation-menu", width: 260) {
            InstallationMenuSnapshot(installations: [Fixtures.installation, classic], selectedID: Fixtures.installation.id)
        }
    }

    // MARK: Inspector

    @Test func inspectorInstalled() throws {
        load(Fixtures.browseInstalled, latest: "v0.5.14")
        try Snapshot.render("inspector-installed", width: 340, height: 820) {
            AddonDetailView(state: state, ref: Fixtures.betterBags.id, missingFolders: [])
        }
    }

    @Test func inspectorNotInstalled() throws {
        load(Fixtures.browseNotInstalled, latest: "5.20.1")
        try Snapshot.render("inspector-not-installed", width: 340, height: 640) {
            AddonDetailView(state: state, ref: Fixtures.browseNotInstalled.id, missingFolders: [])
        }
    }

    @Test func inspectorRetailOnly() throws {
        load(Fixtures.browseRetailOnly, latest: "v1.3")
        try Snapshot.render("inspector-retail-only", width: 340, height: 640) {
            AddonDetailView(state: state, ref: Fixtures.browseRetailOnly.id, missingFolders: [])
        }
    }

    @Test func inspectorUnmanaged() throws {
        load(Fixtures.browseClassicOnly, latest: "v12.0.4")
        try Snapshot.render("inspector-unmanaged", width: 340, height: 720) {
            UnmanagedInspector(queue: state.queue, inspector: state.inspector, unmanaged: Fixtures.questie,
                               adopt: {}, moveToTrash: {})
        }
    }

    @Test func retailBuildSheet() throws {
        try Snapshot.render("retail-build-sheet", width: 420) {
            RetailBuildSheet(name: "Plater", flavor: .forever, install: {})
        }
    }

    // MARK: Sheets

    @Test func adoptSheet() throws {
        try Snapshot.render("adopt-sheet", width: 500) {
            AdoptSheet(target: AdoptTarget(Fixtures.questie), queue: state.queue, browse: state.browse)
        }
    }

    @Test func seedingSheet() throws {
        let refresh = RefreshStatus()
        refresh.progress = RefreshProgress(phase: .support, completed: 132, total: 480, message: "Checking Forever support for WeakAuras…")
        try Snapshot.render("seeding-sheet", width: 460) {
            SeedingSheet(refresh: refresh, flavor: .forever, continueInBackground: {})
        }
    }

    private func load(_ result: SearchResult, latest: String?) {
        let details = Fixtures.details(for: result, latest: latest)
        let blocks = MarkdownParser.renderedBlocks(from: details.readme ?? "", baseURL: details.repositoryURL)
        state.inspector.setDetails(.loaded(details, readme: blocks), for: result.id)
    }
}

// MARK: - Rendering

@MainActor
enum Snapshot {
    /// `<repo>/build/snapshots`, gitignored.
    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "build/snapshots", directoryHint: .isDirectory)

    /// Renders `content` at `width` (and `height`, else its own) in light and dark mode.
    static func render(_ name: String, width: CGFloat, height: CGFloat? = nil, @ViewBuilder content: () -> some View) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
            let view = content()
                .frame(width: width, height: height, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let rendered = try #require(hosted(view, appearance: appearance), "\(name) didn't render")
            let url = directory.appending(path: "\(name)-\(scheme == .dark ? "dark" : "light").png")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, rendered, nil)
            #expect(CGImageDestinationFinalize(destination), "couldn't write \(url.path(percentEncoded: false))")
        }
    }

    /// Draws `view` in an offscreen window, so AppKit-backed pieces (scroll views, borderless
    /// and link buttons, text fields, pickers) render as they do in the app.
    static func hosted(_ view: some View, appearance: NSAppearance) -> CGImage? {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        let size = host.fittingSize
        let window = KeyWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // One run-loop turn lets SwiftUI finish its first update before drawing.
        RunLoop.main.run(until: .now.addingTimeInterval(0.05))
        appearance.performAsCurrentDrawingAppearance { drawSelections(in: host) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        return rep.cgImage
    }
}

/// A selected sidebar row draws its highlight with an `NSVisualEffectView`, which the window
/// server composites and `cacheDisplay` paints black. Swap it for a plain view in the
/// selection colour, so the snapshot shows roughly what the user sees.
@MainActor
private func drawSelections(in view: NSView) {
    if let row = view as? NSTableRowView, row.isSelected {
        for effect in row.subviews.compactMap({ $0 as? NSVisualEffectView }) {
            effect.isHidden = true
            let highlight = NSView(frame: effect.frame)
            highlight.wantsLayer = true
            // Unemphasized (grey) unless the list is first responder, matching the row's text colour.
            let color: NSColor = row.isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
            highlight.layer?.backgroundColor = color.cgColor
            highlight.layer?.cornerRadius = 5
            row.addSubview(highlight, positioned: .below, relativeTo: nil)
        }
    }
    for subview in view.subviews { drawSelections(in: subview) }
}

/// Never shown, but reports itself key so controls draw as in the focused app window
/// (prominent buttons in the accent colour) rather than in their inactive style.
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// A table drawn by hand: a header row, then rows separated like `Table`'s.
private struct TableSnapshot<Rows: View>: View {
    var columns: [(title: String, width: CGFloat)]
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(columns, id: \.title) { column in
                    Text(column.title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        .frame(width: column.width, alignment: .leading)
                }
            }
            .padding(.vertical, 5)
            Divider()
            Group(subviews: rows) { subviews in
                ForEach(subviews) { row in
                    row.padding(.vertical, 5)
                    Divider().opacity(0.5)
                }
            }
        }
        .padding(.horizontal, 10)
    }
}

/// The title menu drawn as a menu panel: menus don't render offscreen, so this lays out the
/// same `InstallationMenuLabel`s with a checkmark column, a divider and the two commands.
private struct InstallationMenuSnapshot: View {
    var installations: [Installation]
    var selectedID: Installation.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(installations) { installation in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold))
                        .opacity(installation.id == selectedID ? 1 : 0)
                    VStack(alignment: .leading, spacing: 1) {
                        InstallationMenuLabel(installation: installation)
                    }
                }
                .padding(.vertical, 2)
            }
            Divider().padding(.vertical, 4)
            Text("Add Installation…").padding(.leading, 18)
            Text("Scan Again").padding(.leading, 18)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }
}

private struct BrowseRowSnapshot: View {
    static let columns: [(title: String, width: CGFloat)] = [("Name", 360), ("Games", 80), ("Last updated", 110), (" ", 190)]
    var state: InstallationModel
    var row: BrowseRow

    var body: some View {
        HStack(spacing: 0) {
            BrowseNameCell(browse: state.browse, row: row).frame(width: 360, alignment: .leading)
            GameBubbles(model: row.games).frame(width: 80, alignment: .leading)
            BrowseUpdatedCell(row: row).frame(width: 110, alignment: .leading)
            BrowseActionCell(queue: state.queue, row: row, rowState: state.queue.row(row.id)).frame(width: 190)
        }
    }
}

private struct InstalledRowSnapshot: View {
    static let columns: [(title: String, width: CGFloat)] = [
        ("Name", 250), ("Version", 190), ("Channel", 80), ("Status", 160), ("Installed", 96), (" ", 110),
    ]
    var state: InstallationModel
    var row: InstalledRow

    var body: some View {
        HStack(spacing: 0) {
            InstalledNameCell(row: row).frame(width: 250, alignment: .leading)
            VersionCell(row: row).frame(width: 190, alignment: .leading)
            ChannelCell(row: row).frame(width: 80, alignment: .leading)
            StatusCell(row: row, flavor: state.installation.flavor).frame(width: 160, alignment: .leading)
            InstalledDateCell(row: row).frame(width: 96, alignment: .leading)
            InstalledActionCell(queue: state.queue, row: row, rowState: state.queue.row(row.id), adopt: {}).frame(width: 110)
        }
    }
}
