import Foundation
import Observation

/// UI state for installing the bundled `reload` (first-launch offer and Settings).
@Observable @MainActor
final class CommandLineToolModel {
    static let didOfferKey = "didOfferCommandLineTool"

    private let installer: CLIInstaller
    private let defaults: UserDefaults
    /// False when running on mock or sandboxed data: the offer is remembered per user.
    private let mayOffer: Bool

    private(set) var status: CLIInstaller.Status = .notInstalled
    private(set) var isWorking = false
    /// Result of the last install/uninstall, shown in Settings.
    private(set) var message: String?
    private(set) var messageIsError = false
    /// Drives the first-launch sheet.
    var isOfferPresented = false

    init(installer: CLIInstaller = .forRunningApp(), defaults: UserDefaults = .standard, mayOffer: Bool) {
        self.installer = installer
        self.defaults = defaults
        self.mayOffer = mayOffer
        refresh()
    }

    var linkPath: String { installer.linkPath }
    var helperPath: String { installer.helperPath }
    var helperExists: Bool { installer.helperExists }

    func refresh() {
        status = installer.status()
    }

    /// Shows the first-launch offer once ever, unless the link already points at this app.
    func offerIfNeeded() {
        guard mayOffer, !defaults.bool(forKey: Self.didOfferKey) else { return }
        refresh()
        guard status != .installed, installer.helperExists else { return }
        defaults.set(true, forKey: Self.didOfferKey)
        isOfferPresented = true
    }

    /// Creates the link, asking for an admin password. Returns the error, if any
    /// (`CLIInstaller.Failure.cancelled` when the prompt was dismissed).
    @discardableResult
    func install() async -> (any Error)? {
        let installer = self.installer
        let error = await run { try installer.install() }
        if error == nil {
            message = "Installed at \(linkPath)."
            messageIsError = false
        }
        return error
    }

    func uninstall() async {
        let installer = self.installer
        if await run({ try installer.uninstall() }) == nil {
            message = "Removed \(linkPath)."
            messageIsError = false
        }
    }

    private func run(_ body: @escaping @Sendable () throws -> Void) async -> (any Error)? {
        isWorking = true
        defer {
            isWorking = false
            refresh()
        }
        message = nil
        do {
            // The password prompt blocks its thread, so keep it off the main actor.
            try await Task.detached(priority: .userInitiated) { try body() }.value
            return nil
        } catch CLIInstaller.Failure.cancelled {
            message = "The password prompt was cancelled; nothing was changed."
            messageIsError = false
            return CLIInstaller.Failure.cancelled
        } catch {
            message = error.localizedDescription
            messageIsError = true
            return error
        }
    }
}
