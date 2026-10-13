import AddonKit
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
            "AltIcon-Classic", "AltIcon-Rune", "AltIcon-Scroll", "AltIcon-Gilded",
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
    @Test func resetRedoesBothStepsAndNothingElse() {
        let name = "FirstLaunchStepsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "didSeedAddonDetails")
        defaults.set(true, forKey: "didOfferCommandLineTool")
        defaults.set("dark", forKey: SettingsKey.appearance)

        FirstLaunchSteps.reset(in: defaults)

        #expect(defaults.object(forKey: "didSeedAddonDetails") as? Bool == false)
        #expect(defaults.object(forKey: "didOfferCommandLineTool") == nil)
        #expect(defaults.string(forKey: SettingsKey.appearance) == "dark")
    }

    @Test func aResetSeedsAgainEvenAfterARefresh() {
        #expect(FirstLaunchSteps.needsSeeding(didSeed: false, hasRefreshed: true))
        #expect(!FirstLaunchSteps.needsSeeding(didSeed: true, hasRefreshed: false))
        // Never stored: seeding depends on whether a refresh ever completed.
        #expect(FirstLaunchSteps.needsSeeding(didSeed: nil, hasRefreshed: false))
        #expect(!FirstLaunchSteps.needsSeeding(didSeed: nil, hasRefreshed: true))
    }

    @Test func sandboxedDataHasNothingToReset() {
        let model = AppModel(manager: FixtureManager(), usesStandardDefaults: false)
        #expect(!model.remembersFirstLaunchSteps)
    }
}

@Suite struct GitHubTokenSourceTests {
    @Test func environmentWinsOverTheKeychain() {
        #expect(GitHubTokenSource(environment: ["GITHUB_TOKEN": "x"], hasKeychainToken: true) == .environment("GITHUB_TOKEN"))
        #expect(GitHubTokenSource(environment: ["GITHUB_TOKEN": "x", "RELOAD_GITHUB_TOKEN": "y"], hasKeychainToken: false)
            == .environment("RELOAD_GITHUB_TOKEN"))
    }

    @Test func blankVariablesAreIgnored() {
        #expect(GitHubTokenSource(environment: ["GITHUB_TOKEN": "  "], hasKeychainToken: true) == .keychain)
        #expect(GitHubTokenSource(environment: [:], hasKeychainToken: false) == .none)
    }
}

@MainActor @Suite struct GitHubStatusDisplayTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func unknownStatusSaysNotUsedYet() {
        let display = GitHubStatusDisplay(status: GitHubStatus(), now: now)
        #expect(display.api == GitHubQuotaDisplay(value: "Not used yet", fraction: nil, detail: "60 an hour"))
        #expect(display.search == GitHubQuotaDisplay(value: "Not used yet", fraction: nil, detail: "10 a minute"))
        #expect(display.pauseWarning == nil)
    }

    @Test func partlySpentQuotaShowsWhatsLeftAndTheReset() {
        let status = GitHubStatus(api: RateLimitState(remaining: 42, resetAt: now.addingTimeInterval(23 * 60)), apiLimit: 60)
        let api = GitHubStatusDisplay(status: status, now: now).api
        #expect(api.value == "42 of 60 left")
        #expect(api.fraction == 0.7)
        #expect(api.detail == "Resets in 23 min")
        #expect(!api.isExhausted)
    }

    @Test func tokenRaisesTheLimits() {
        let status = GitHubStatus(api: RateLimitState(remaining: 4_990), search: RateLimitState(remaining: 29), hasToken: true)
        let display = GitHubStatusDisplay(status: status, now: now)
        #expect(display.api.value == "\(4_990.formatted()) of \(5_000.formatted()) left")
        #expect(display.api.detail == "\(5_000.formatted()) an hour")
        #expect(display.search.value == "29 of 30 left")
    }

    @Test func usedUpQuotaIsFlagged() {
        let status = GitHubStatus(search: RateLimitState(remaining: 0, resetAt: now.addingTimeInterval(40)))
        let search = GitHubStatusDisplay(status: status, now: now).search
        #expect(search == GitHubQuotaDisplay(value: "0 of 10 left", fraction: 0, detail: "Used up, resets in under a minute", isExhausted: true))
    }

    @Test func pastResetShowsAFullWindow() {
        let status = GitHubStatus(api: RateLimitState(remaining: 3, resetAt: now.addingTimeInterval(-5)), apiLimit: 60)
        #expect(GitHubStatusDisplay(status: status, now: now).api == GitHubQuotaDisplay(value: "60 of 60 left", fraction: 1, detail: "60 an hour"))
    }

    @Test func pauseWarningOnlyWhileInTheFuture() {
        let paused = GitHubStatus(webPausedUntil: now.addingTimeInterval(4 * 60 + 10))
        #expect(GitHubStatusDisplay(status: paused, now: now).pauseWarning == "github.com asked us to slow down — resumes in 5 min.")
        let over = GitHubStatus(webPausedUntil: now.addingTimeInterval(-1))
        #expect(GitHubStatusDisplay(status: over, now: now).pauseWarning == nil)
    }

    @Test func durationsRoundUp() {
        #expect(GitHubStatusDisplay.duration(from: now, to: now.addingTimeInterval(59)) == "under a minute")
        #expect(GitHubStatusDisplay.duration(from: now, to: now.addingTimeInterval(61)) == "2 min")
        #expect(GitHubStatusDisplay.duration(from: now, to: now.addingTimeInterval(3_600)) == "1 hr")
        #expect(GitHubStatusDisplay.duration(from: now, to: now.addingTimeInterval(3_900)) == "1 hr 5 min")
    }
}

@MainActor @Suite struct GitHubStatusModelTests {
    @Test func refreshReadsTheManager() async {
        let model = GitHubStatusModel()
        #expect(model.status == nil)
        await model.refresh(from: FixtureManager())
        #expect(model.status == Fixtures.gitHubStatus)
    }
}

/// Settings saved under earlier bundle IDs carry over once (decisions 0024, 0026).
@Suite struct LegacyDefaultsTests {
    @Test func copiesOnceWithoutOverwriting() throws {
        let name = "LegacyDefaultsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dark", forKey: SettingsKey.appearance)
        AppEnvironment.migrateLegacyDefaults(into: defaults, from: [[SettingsKey.appearance: "light", SettingsKey.appIcon: "rune"]])
        #expect(defaults.string(forKey: SettingsKey.appearance) == "dark")
        #expect(defaults.string(forKey: SettingsKey.appIcon) == "rune")
        AppEnvironment.migrateLegacyDefaults(into: defaults, from: [[SettingsKey.appIcon: "gilded"]])
        #expect(defaults.string(forKey: SettingsKey.appIcon) == "rune", "runs once")
    }

    @Test func newestDomainWins() throws {
        let name = "LegacyDefaultsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        AppEnvironment.migrateLegacyDefaults(into: defaults, from: [
            [SettingsKey.appIcon: "rune"],
            [SettingsKey.appIcon: "gilded", SettingsKey.appearance: "light"],
        ])
        #expect(defaults.string(forKey: SettingsKey.appIcon) == "rune")
        #expect(defaults.string(forKey: SettingsKey.appearance) == "light", "older domains still fill gaps")
    }
}
