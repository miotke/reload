import Foundation
import Sparkle

/// Starts Sparkle and mirrors it into an `AppUpdater` (docs/app/updates.md). Excluded from
/// the unit-test bundle, which doesn't link Sparkle.
final class SparkleUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    /// Nil in Debug builds: a development copy must never update itself to a release.
    static func make() -> AppUpdater? {
        #if DEBUG
        return nil
        #else
        let owner = SparkleUpdater()
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: owner, userDriverDelegate: nil)
        let updater = controller.updater
        owner.controller = controller
        let model = AppUpdater(
            automaticallyChecks: updater.automaticallyChecksForUpdates, owner: owner,
            check: { controller.checkForUpdates(nil) },
            setAutomaticallyChecks: { updater.automaticallyChecksForUpdates = $0 })
        owner.observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak model] updater, _ in
            MainActor.assumeIsolated { model?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        return model
        #endif
    }

    /// `RELOAD_UPDATE_FEED=<url>` points a release build at a test feed. It still has to be
    /// signed with the release key, so this can't install anything the real feed couldn't.
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let feed = ProcessInfo.processInfo.environment["RELOAD_UPDATE_FEED"], !feed.isEmpty else { return nil }
        return feed
    }
}
