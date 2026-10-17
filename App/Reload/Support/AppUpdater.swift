import Observation

/// Reload's own updates, as the app menu and Settings see them (docs/app/updates.md).
///
/// `SparkleUpdater` creates and drives it in Release builds. Debug builds have none, so a
/// development copy never replaces itself with a published release. Plain closures keep
/// Sparkle out of everything that shows it, including the unit-test bundle.
@Observable
final class AppUpdater {
    /// False while Sparkle is already checking, downloading or showing an update.
    var canCheckForUpdates = false

    /// Sparkle stores the choice itself (`SUEnableAutomaticChecks` in user defaults).
    var automaticallyChecks: Bool {
        didSet {
            if automaticallyChecks != oldValue { setAutomaticallyChecks(automaticallyChecks) }
        }
    }

    @ObservationIgnored private let check: () -> Void
    @ObservationIgnored private let setAutomaticallyChecks: (Bool) -> Void
    /// Whatever has to live as long as this model: the Sparkle controller and its observers.
    @ObservationIgnored private let owner: AnyObject?

    init(automaticallyChecks: Bool, owner: AnyObject? = nil,
         check: @escaping () -> Void, setAutomaticallyChecks: @escaping (Bool) -> Void) {
        self.automaticallyChecks = automaticallyChecks
        self.owner = owner
        self.check = check
        self.setAutomaticallyChecks = setAutomaticallyChecks
    }

    /// Shows Sparkle's window: "up to date", or the new version with its notes.
    func checkForUpdates() {
        check()
    }
}
