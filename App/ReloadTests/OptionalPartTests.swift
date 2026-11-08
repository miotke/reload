import AddonKit
import Foundation
import Testing

/// The inspector's Optional Parts: rows map the core's `OptionalPart`, and the model asks
/// for the stored answer before revalidating (docs/app/optional-parts.md).
@MainActor @Suite struct OptionalPartTests {
    static func part(_ folder: String, prefix: String, version: String, size: Int64?, state: OptionalPart.State,
                     usedBy: [String] = ["Spoken_Places"]) -> OptionalPart {
        OptionalPart(ref: AddonRef(source: .github, identifier: "example/Spoken", tagPrefix: prefix), folder: folder,
                     usedBy: usedBy, version: "\(prefix)/\(version)", downloadSize: size, state: state)
    }

    static let places = part("SpokenPlacesAudio", prefix: "places-audio", version: "v2.1.0", size: 435_000_000, state: .available)
    static let npcs = part("SpokenNPCAudio", prefix: "npc-audio", version: "v1.0.0", size: 210_000_000, state: .unmanaged, usedBy: [])
    static let emotes = part("SpokenEmotes", prefix: "emotes", version: "v0.3.0", size: nil, state: .installed)

    @Test func availablePartOffersInstallWithItsSize() {
        let row = OptionalPartRow(Self.places)
        #expect(row.name == "SpokenPlacesAudio")
        #expect(row.action == .install)
        #expect(row.actionTitle == "Install (435 MB)")
        #expect(row.detail == "v2.1.0 · Used by Spoken_Places")
        #expect(row.rowID == "github:example/Spoken#places-audio")
    }

    @Test func unmanagedPartOffersManageOnTheFoldersRow() {
        let row = OptionalPartRow(Self.npcs)
        #expect(row.action == .manage)
        #expect(row.actionTitle == "Manage…")
        #expect(row.detail == "v1.0.0 · 210 MB")
        #expect(row.rowID == AddonStatus.unmanagedID("SpokenNPCAudio"))
        #expect(row.manageMessage.hasPrefix("Reload downloads SpokenNPCAudio v1.0.0 (210 MB) from GitHub"))
    }

    @Test func installedPartIsAQuietMark() {
        let row = OptionalPartRow(Self.emotes)
        #expect(row.action == .installed)
        #expect(row.actionTitle == "Installed")
        #expect(row.size == nil)
        #expect(row.detail == "v0.3.0 · Used by Spoken_Places")
        var noSize = Self.places
        noSize.downloadSize = nil
        #expect(OptionalPartRow(noSize).actionTitle == "Install")
    }

    @Test func versionKeepsTagsWithoutThePrefix() {
        var part = Self.places
        part.version = "2.1.0"
        #expect(OptionalPartRow.version(part) == "2.1.0")
    }

    @Test func prefixedRefsRoundTripThroughRowIDs() {
        let ref = Self.places.ref
        #expect(AddonRef(rowID: ref.description) == ref)
        #expect(AddonRef(rowID: ref.description)?.repo == AddonRef(source: .github, identifier: "example/Spoken"))
        #expect(ref.repositoryText == "example/Spoken · places-audio")
        #expect(ref.repo.repositoryText == "example/Spoken")
        let row = InstalledRow(status: .managed(Fixtures.addon("example/Spoken", "Spoken", version: "1"), missingFolders: []),
                               update: nil, flavor: .forever)
        #expect(row.subtitle == "example/Spoken")
    }

    func state(_ manager: FixtureManager) -> InstallationModel {
        InstallationModel(installation: Fixtures.installation, manager: manager, reportError: { _ in })
    }

    @Test func loadsStoredThenRevalidated() async {
        var manager = FixtureManager()
        manager.optionalPartsByPolicy = [.preferStored: [Self.places], .revalidateIfStale: [Self.places, Self.npcs]]
        let state = state(manager)
        let ref = Fixtures.littleWigs.id
        await state.inspector.loadOptionalParts(for: ref)
        #expect(state.inspector.optionalParts[ref]?.rows.map(\.id) == [Self.places.id, Self.npcs.id])
        #expect(state.inspector.optionalParts[ref]?.error == nil)
    }

    @Test func noPartsLeavesTheListEmpty() async {
        let state = state(FixtureManager())
        await state.inspector.loadOptionalParts(for: Fixtures.littleWigs.id)
        #expect(state.inspector.optionalParts[Fixtures.littleWigs.id]?.rows.isEmpty == true)
        // Nothing shown, nothing to reload.
        #expect(self.state(FixtureManager()).inspector.reloadOptionalParts() == nil)
    }

    @Test func failedRevalidateKeepsStoredRows() async {
        var manager = FixtureManager()
        manager.optionalPartsByPolicy = [.preferStored: [Self.places]]
        let state = state(manager)
        let ref = Fixtures.littleWigs.id
        await state.inspector.loadOptionalParts(for: ref)
        #expect(state.inspector.optionalParts[ref]?.rows.map(\.id) == [Self.places.id])
        #expect(state.inspector.optionalParts[ref]?.error != nil)
    }

    @Test func listAppliesOnlyChanges() {
        let list = OptionalPartsList(ref: Fixtures.littleWigs.id)
        list.fail("offline")
        list.apply([Self.places])
        #expect(list.error == nil)
        #expect(list.rows == [OptionalPartRow(Self.places)])
        var installed = Self.places
        installed.state = .installed
        list.apply([installed])
        #expect(list.rows.first?.action == .installed)
    }
}
