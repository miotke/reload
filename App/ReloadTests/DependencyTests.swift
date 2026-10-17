import AddonKit
import Foundation
import Testing

/// Wording and follow-ups for required add-ons: the app only maps the core's
/// `MissingDependency` and dependents (docs/app/required-addons.md).
@MainActor @Suite struct DependencyWordingTests {
    @Test func listsAFewNamesThenCountsTheRest() {
        #expect(DependencyWording.list([]) == "")
        #expect(DependencyWording.list(["A"]) == "A")
        #expect(DependencyWording.list(["A", "B"]) == "A and B")
        #expect(DependencyWording.list(["A", "B", "C"]) == "A, B and C")
        #expect(DependencyWording.list(["A", "B", "C", "D"]) == "A, B, C and 1 other")
        #expect(DependencyWording.list(["A", "B", "C", "D", "E"]) == "A, B, C and 2 others")
    }

    @Test func statusNamesOneFolderAndCountsSeveral() {
        #expect(DependencyWording.status([]) == nil)
        #expect(DependencyWording.status(["BigWigs"]) == "Needs BigWigs")
        #expect(DependencyWording.status(["BigWigs", "LibStub"]) == "Needs 2 add-ons")
        #expect(DependencyWording.statusHelp(name: "LittleWigs", folders: ["BigWigs"])
            == "BigWigs isn't installed. The game won't load LittleWigs until it is.")
        #expect(DependencyWording.statusHelp(name: "LittleWigs", folders: ["BigWigs", "LibStub"])
            == "BigWigs and LibStub aren't installed. The game won't load LittleWigs until they are.")
    }

    @Test func installedRowShowsMissingDependencies() {
        let addon = Fixtures.littleWigs
        let row = InstalledRow(status: .managed(addon, missingFolders: []), update: .upToDate, flavor: .forever,
                               missingDependencies: ["BigWigs"])
        #expect(row.condition == .missingDependencies)
        #expect(row.dependencyText == "Needs BigWigs")
        #expect(row.dependencyHelp == "BigWigs isn't installed. The game won't load LittleWigs until it is.")
        // Missing its own files still comes first; an update comes after.
        let broken = InstalledRow(status: .managed(addon, missingFolders: ["LittleWigs"]), update: nil, flavor: .forever,
                                  missingDependencies: ["BigWigs"])
        #expect(broken.condition == .missingFolders)
        #expect(InstalledRow.Condition.missingDependencies < .updateAvailable)
        // An update is still offered, so the row stays in Updates.
        let update = InstalledRow(status: .managed(addon, missingFolders: []),
                                  update: .available(Fixtures.release("BigWigsMods/LittleWigs", "LittleWigs", version: "v11.2.7")),
                                  flavor: .forever, missingDependencies: ["BigWigs"])
        #expect(update.condition == .missingDependencies && LibrarySection.updates.includes(update))
        let fine = InstalledRow(status: .managed(addon, missingFolders: []), update: .upToDate, flavor: .forever)
        #expect(fine.condition == .upToDate && fine.dependencyText == nil)
    }

    @Test func removalMessageNamesDependents() {
        let bigWigs = Fixtures.addon("BigWigsMods/BigWigs", "BigWigs", version: "v400", folders: ["BigWigs", "BigWigs_Core"])
        let plain = "Removes BigWigs, BigWigs_Core from Interface/AddOns. Saved settings are kept."
        #expect(RemovalRequest.managed(bigWigs).message == plain)
        #expect(RemovalRequest.managed(bigWigs, dependents: [Fixtures.littleWigs]).message
            == "LittleWigs needs BigWigs and will stop loading. " + plain)
        let many = ["A", "B", "C", "D", "E"].map { Fixtures.addon("o/\($0)", $0, version: "1") }
        #expect(RemovalRequest.managed(bigWigs, dependents: many).message
            == "A, B, C and 2 others need BigWigs and will stop loading. " + plain)
        #expect(RemovalRequest.managed(bigWigs, dependents: many).id == bigWigs.id.description)
    }
}

@MainActor @Suite struct DependencyFollowUpTests {
    let installation = Fixtures.installation.id

    func followUp(_ missing: [MissingDependency], _ policy: DependencyPolicy) -> DependencyFollowUp {
        DependencyFollowUp(addonName: "LittleWigs", missing: missing, policy: policy, installationID: installation)
    }

    @Test func eachPolicy() {
        let missing = Fixtures.missingDependencies
        guard case .ask(let prompt) = followUp(missing, .ask) else {
            Issue.record("expected a prompt")
            return
        }
        #expect(prompt.title == "LittleWigs needs BigWigs")
        #expect(prompt.message == "Install BigWigs too?")
        #expect(prompt.candidates == [Fixtures.bigWigs] && prompt.installationID == installation)
        #expect(followUp(missing, .install) == .install([Fixtures.bigWigs]))
        #expect(followUp(missing, .warn) == .nothing)
    }

    @Test func neverOffersFoldersWithoutASuggestion() {
        let unsure = Array(Fixtures.missingDependencyKinds.dropFirst())
        for policy in DependencyPolicy.allCases {
            #expect(followUp(unsure, policy) == .nothing)
            #expect(followUp([], policy) == .nothing)
        }
        // Mixed: only the suggested one is offered.
        guard case .ask(let prompt) = followUp(Fixtures.missingDependencyKinds, .ask) else {
            Issue.record("expected a prompt")
            return
        }
        #expect(prompt.folders == ["BigWigs"] && prompt.candidates == [Fixtures.bigWigs])
    }

    @Test func onePromptForSeveralFoldersOfOneAddon() {
        let core = MissingDependency(folder: "BigWigs_Core", requiredBy: [Fixtures.littleWigs.id],
                                     candidates: [Fixtures.bigWigs], suggested: Fixtures.bigWigs)
        let library = DependencyCandidate(ref: Fixtures.ref("example/LibStub"), name: "LibStub", reason: "ships it")
        let stub = MissingDependency(folder: "LibStub", requiredBy: [Fixtures.littleWigs.id], candidates: [library], suggested: library)
        guard case .ask(let prompt) = followUp(Fixtures.missingDependencies + [core, stub], .ask) else {
            Issue.record("expected a prompt")
            return
        }
        #expect(prompt.title == "LittleWigs needs BigWigs, BigWigs_Core and LibStub")
        #expect(prompt.message == "Install BigWigs and LibStub too?")
        #expect(followUp(Fixtures.missingDependencies + [core], .install) == .install([Fixtures.bigWigs]))
    }

    @Test func storedSettingsDefaults() {
        let name = "DependencyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(DependencyPolicy.stored(in: defaults) == .ask)
        defaults.set("sometimes", forKey: SettingsKey.dependencyPolicy)
        #expect(DependencyPolicy.stored(in: defaults) == .ask)
        defaults.set(DependencyPolicy.install.rawValue, forKey: SettingsKey.dependencyPolicy)
        #expect(DependencyPolicy.stored(in: defaults) == .install)
        #expect(Set(DependencyPolicy.allCases.map(\.title)).count == DependencyPolicy.allCases.count)
    }

    @Test func removalWarningIsOnByDefault() {
        let name = "DependencyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(RemovalWarning.isOn(in: defaults))
        defaults.set(false, forKey: SettingsKey.warnBeforeRemovingDependencies)
        #expect(!RemovalWarning.isOn(in: defaults))
    }
}

/// The models over the test-only `FixtureManager`.
@MainActor @Suite struct DependencyModelTests {
    func state(_ manager: FixtureManager = FixtureManager()) async -> InstallationModel {
        let state = InstallationModel(installation: Fixtures.installation, manager: manager, reportError: { _ in })
        state.queue.dependencyPolicy = { .ask }
        state.queue.warnsBeforeRemovingDependencies = { true }
        state.queue.defaultChannel = { .stable }
        await state.installed.reload()
        return state
    }

    /// The inspector's Search for a required add-on (`AppModel.searchBrowse(for:)`).
    func revealSearch(_ text: String, in state: InstallationModel, typed: String? = nil) async {
        state.browse.revealQuery = text
        state.browse.options = BrowseOptions(query: typed ?? text)
        await state.browse.search(SearchQuery(text: typed ?? text, flavor: Fixtures.installation.flavor))
    }

    @Test func searchForARequiredAddonSelectsTheFirstResult() async {
        var manager = FixtureManager()
        manager.searchResults = [Fixtures.browseNotInstalled, Fixtures.browseInstalled]
        let state = await state(manager)
        await revealSearch("BigWigs", in: state)
        #expect(state.inspector.selectedBrowseID == state.browse.rows.first?.id)
        #expect(state.inspector.selectedBrowseID != nil)
        #expect(state.browse.revealQuery == nil)
    }

    @Test func searchForARequiredAddonThatFindsNothingClearsTheSelection() async {
        let state = await state()
        state.inspector.selectedBrowseID = state.browse.row(for: Fixtures.browseInstalled).id
        await revealSearch("ArcaneWizardLibrary", in: state)
        #expect(state.browse.rows.isEmpty)
        #expect(state.inspector.selectedBrowseID == nil)
    }

    @Test func typingSomethingElseCancelsTheReveal() async {
        var manager = FixtureManager()
        manager.searchResults = [Fixtures.browseNotInstalled]
        let state = await state(manager)
        await revealSearch("BigWigs", in: state, typed: "bags")
        #expect(state.inspector.selectedBrowseID == nil)
        #expect(state.browse.revealQuery == nil)
    }

    @Test func reloadMapsMissingDependenciesOntoRows() async {
        let state = await state()
        let row = state.installed.rows.first { $0.ref == Fixtures.littleWigs.id }
        #expect(row?.dependencyText == "Needs BigWigs")
        #expect(row?.condition == .missingDependencies)
        // Looked up case-insensitively, like the managed list.
        let lowered = AddonRef(source: .github, identifier: "bigwigsmods/littlewigs")
        #expect(state.installed.missingDependencies(for: lowered).map(\.folder) == ["BigWigs"])
        #expect(state.installed.missingDependencies(for: Fixtures.betterBags.id).isEmpty)
        #expect(state.installed.rows.filter { $0.dependencyText != nil }.count == 1)
    }

    @Test func installAsksAboutTheSuggestedAddon() async {
        var manager = FixtureManager()
        manager.installable = [Fixtures.littleWigs.id: Fixtures.littleWigs]
        let state = await state(manager)
        var prompts: [DependencyPrompt] = []
        state.queue.didFindMissingDependencies = { prompts.append($0) }
        await state.queue.install(Fixtures.littleWigs.id, channel: .stable)
        #expect(prompts.map(\.title) == ["LittleWigs needs BigWigs"])

        prompts = []
        state.queue.dependencyPolicy = { .warn }
        await state.queue.install(Fixtures.littleWigs.id, channel: .stable)
        #expect(prompts.isEmpty)
    }

    @Test func installPolicyInstallsThroughTheQueue() async {
        var manager = FixtureManager()
        let bigWigs = Fixtures.addon("BigWigsMods/BigWigs", "BigWigs", version: "v400")
        manager.installable = [Fixtures.littleWigs.id: Fixtures.littleWigs, bigWigs.id: bigWigs]
        let state = await state(manager)
        state.queue.dependencyPolicy = { .install }
        var installedRefs: [AddonRef] = []
        state.queue.didInstall = { installedRefs.append($0.id) }
        var prompts = 0
        state.queue.didFindMissingDependencies = { _ in prompts += 1 }
        await state.queue.install(Fixtures.littleWigs.id, channel: .stable)
        #expect(installedRefs == [Fixtures.littleWigs.id, bigWigs.id])
        #expect(prompts == 0)
    }

    @Test func failedDependencyInstallShowsOnItsRow() async {
        var manager = FixtureManager()
        manager.installable = [Fixtures.littleWigs.id: Fixtures.littleWigs]
        let state = await state(manager)
        state.queue.dependencyPolicy = { .install }
        await state.queue.install(Fixtures.littleWigs.id, channel: .stable)
        #expect(state.queue.row(Fixtures.bigWigs.ref.description).error != nil)
        #expect(state.queue.row(Fixtures.littleWigs.id.description).error == nil)
    }

    @Test func removalDependentsFollowTheSetting() async {
        var manager = FixtureManager()
        let bigWigs = Fixtures.ref("BigWigsMods/BigWigs")
        manager.dependentsByRef = [bigWigs: [Fixtures.littleWigs]]
        let state = await state(manager)
        #expect(await state.queue.removalDependents(of: bigWigs) == [Fixtures.littleWigs])
        state.queue.warnsBeforeRemovingDependencies = { false }
        #expect(await state.queue.removalDependents(of: bigWigs).isEmpty)
    }
}
