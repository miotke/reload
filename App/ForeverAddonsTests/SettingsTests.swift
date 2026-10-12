import Foundation
import Testing

@MainActor @Suite struct AppIconChoiceTests {
    func defaults() -> UserDefaults {
        let name = "SettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func classicIsTheDefault() {
        #expect(AppIconChoice.stored(in: defaults()) == .classic)
    }

    @Test func storageRoundTrips() {
        let defaults = defaults()
        for choice in AppIconChoice.allCases {
            choice.store(in: defaults)
            #expect(defaults.string(forKey: SettingsKey.appIcon) == choice.rawValue)
            #expect(AppIconChoice.stored(in: defaults) == choice)
        }
    }

    @Test func unknownStoredValueFallsBackToClassic() {
        let defaults = defaults()
        defaults.set("sparkles", forKey: SettingsKey.appIcon)
        #expect(AppIconChoice.stored(in: defaults) == .classic)
    }

    @Test func assetNamesMatchTheArtworkContract() {
        #expect(AppIconChoice.allCases.map(\.assetName) == [
            "AltIcon-Classic", "AltIcon-Rune", "AltIcon-Scroll", "AltIcon-Shield", "AltIcon-Midnight", "AltIcon-Gilded",
        ])
        #expect(Set(AppIconChoice.allCases.map(\.title)).count == AppIconChoice.allCases.count)
    }

    @Test func classicUsesTheBundleIcon() {
        #expect(AppIconChoice.classic.dockImage == nil)
    }

    @Test func missingArtworkLeavesTheBundleIcon() {
        // The test bundle has no asset catalog, so no artwork loads.
        #expect(AppIconChoice.allCases.allSatisfy { $0.image == nil && $0.dockImage == nil })
    }
}

@MainActor @Suite struct FirstLaunchStepsTests {
    @Test func resetClearsBothStepsAndNothingElse() {
        let name = "FirstLaunchStepsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "didSeedAddonDetails")
        defaults.set(true, forKey: "didOfferCommandLineTool")
        defaults.set("dark", forKey: SettingsKey.appearance)

        FirstLaunchSteps.reset(in: defaults)

        #expect(defaults.object(forKey: "didSeedAddonDetails") == nil)
        #expect(defaults.object(forKey: "didOfferCommandLineTool") == nil)
        #expect(defaults.string(forKey: SettingsKey.appearance) == "dark")
    }

    @Test func sandboxedDataHasNothingToReset() {
        let model = AppModel(manager: FixtureManager(), usesStandardDefaults: false)
        #expect(!model.remembersFirstLaunchSteps)
    }
}

@Suite struct GitHubTokenSourceTests {
    @Test func environmentWinsOverTheKeychain() {
        #expect(GitHubTokenSource(environment: ["GITHUB_TOKEN": "x"], hasKeychainToken: true) == .environment("GITHUB_TOKEN"))
        #expect(GitHubTokenSource(environment: ["GITHUB_TOKEN": "x", "ADDONS_GITHUB_TOKEN": "y"], hasKeychainToken: false)
            == .environment("ADDONS_GITHUB_TOKEN"))
    }

    @Test func blankVariablesAreIgnored() {
        #expect(GitHubTokenSource(environment: ["GITHUB_TOKEN": "  "], hasKeychainToken: true) == .keychain)
        #expect(GitHubTokenSource(environment: [:], hasKeychainToken: false) == .none)
    }
}
