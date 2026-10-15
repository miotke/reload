import Foundation
import Testing
@testable import AddonKit

/// The decisions front ends display rather than make: install action, Browse filtering,
/// visible-row order and adoption.
@Suite struct InstallActionTests {
    let ref = AddonRef(source: .github, identifier: "o/r")

    func release(_ version: String, flavorBuild: Flavor? = nil) -> ResolvedRelease {
        ResolvedRelease(ref: ref, name: "R", version: version, releaseID: 2, publishedAt: .now,
                        downloadURL: URL(string: "https://x")!, assetName: "R.zip", flavorBuild: flavorBuild)
    }

    @Test func notInstalled() {
        #expect(InstallAction(installed: nil, update: nil, availableFlavors: nil, flavor: .forever) == .install)
        #expect(InstallAction(installed: nil, update: nil, availableFlavors: [.forever, .mainline], flavor: .forever) == .install)
        #expect(InstallAction(installed: nil, update: nil, availableFlavors: [.mainline], flavor: .forever) == .installFallbackBuild(.mainline))
        // Retail has no fallback; classic-only offers nothing.
        #expect(InstallAction(installed: nil, update: nil, availableFlavors: [.forever], flavor: .mainline) == .install)
        #expect(InstallAction(installed: nil, update: nil, availableFlavors: [.vanilla], flavor: .forever) == .install)
        #expect(!InstallAction.installFallbackBuild(.mainline).isInstalled)
    }

    @Test func installedAndUpdates() {
        var addon = sampleInstalledAddon("o/r", name: "R", folders: ["R"])
        #expect(InstallAction(installed: addon, update: .upToDate, availableFlavors: [.mainline], flavor: .forever) == .installed(ref: ref, version: "v1"))
        #expect(InstallAction(installed: addon, update: .available(release("v2")), availableFlavors: nil, flavor: .forever)
            == .update(ref: ref, version: "v1", to: .version("v2")))
        #expect(InstallAction(installed: addon, update: nil, availableFlavors: nil, flavor: .forever).installedRef == ref)

        addon.pinned = true
        #expect(InstallAction(installed: addon, update: .available(release("v2")), availableFlavors: nil, flavor: .forever) == .installed(ref: ref, version: "v1"))
    }

    @Test func aFallbackBuildUpdatesToTheOwnBuild() {
        var addon = sampleInstalledAddon("o/r", name: "R", folders: ["R"])
        addon.installedFlavorBuild = .mainline
        #expect(UpdateOffer(installed: addon, update: .available(release("v1")), flavor: .forever) == .ownBuild(.forever))
        #expect(UpdateOffer(installed: addon, update: .available(release("v2", flavorBuild: .mainline)), flavor: .forever) == .version("v2"))
        #expect(UpdateOffer(installed: addon, update: .upToDate, flavor: .forever) == nil)
    }

    @Test func browseFilter() {
        var result = SearchResult(id: ref, name: "R", owner: "o", availableFlavors: [.vanilla], origin: [.catalogue])
        #expect(BrowseFilter.isHidden(result, for: .forever, isInstalled: false))
        #expect(!BrowseFilter.isHidden(result, for: .forever, isInstalled: true), "installed rows always show")
        #expect(!BrowseFilter.hasConfirmedBuild(result, for: .forever))
        result.availableFlavors = [.mainline]
        #expect(!BrowseFilter.isHidden(result, for: .forever, isInstalled: false))
        result.availableFlavors = nil
        result.support = .supported(version: "v1")
        #expect(BrowseFilter.hasConfirmedBuild(result, for: .forever))
    }

    @Test func gamesFilter() {
        var result = SearchResult(id: ref, name: "R", owner: "o", availableFlavors: [.mainline], origin: [.catalogue])
        #expect(BrowseFilter.isHidden(result, games: .forever, isInstalled: false), "a Retail-only build has no F bubble")
        #expect(!BrowseFilter.isHidden(result, games: .forever, isInstalled: true), "installed rows always show")
        #expect(!BrowseFilter.isHidden(result, games: .retail, isInstalled: false))
        #expect(!BrowseFilter.isHidden(result, games: nil, isInstalled: false))
        result.availableFlavors = [.mists]
        #expect(!BrowseFilter.isHidden(result, games: .classic, isInstalled: false))
        result.availableFlavors = nil
        #expect(!BrowseFilter.isHidden(result, games: .classic, isInstalled: false), "unchecked rows stay")
        result.support = .noReleases
        #expect(BrowseFilter.isHidden(result, games: .classic, isInstalled: false))
    }

    @Test func visibleCheckTargetsPutUncheckedFirst() {
        let refs = (0..<30).map { AddonRef(source: .github, identifier: "o/r\($0)") }
        let checked = Set(refs.prefix(5))
        let targets = AddonManager.visibleCheckTargets(refs, isChecked: checked.contains)
        #expect(targets.count == AddonManager.visibleCheckLimit)
        #expect(targets.first == refs[5])
        #expect(!targets.contains(refs[0]), "checked rows only fill what's left")
    }

    @Test func refsAndAdoption() {
        #expect(AddonRef(parsing: "https://github.com/O/R.git") == AddonRef(source: .github, identifier: "O/R"))
        #expect(AddonRef(parsing: "owner/repo/extra") == nil)
        #expect(ref.isSameRepo(as: AddonRef(source: .github, identifier: "O/R")))
        #expect(!ref.isSameRepo(as: AddonRef(source: .github, identifier: "o/other")))
        let preview = AdoptionPreview(release: release("v1"), folders: ["R"], replaces: ["R"], adds: [])
        #expect(preview.canAdopt)
        #expect(!AdoptionPreview(release: release("v1"), folders: ["R"], replaces: [], adds: [], conflicts: ["R": ref]).canAdopt)
    }
}
