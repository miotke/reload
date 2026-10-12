import Foundation

/// The app and CLI were called ForeverAddons (bundle ID `com.andrewmiotke.ForeverAddons`)
/// before they were Reload (decision 0024). This moves the old data across once.
public enum LegacyDataMigration {
    public static let legacyBundleID = "com.andrewmiotke.ForeverAddons"

    /// Moves the legacy Application Support and Caches folders to `directories` when the new
    /// ones don't exist yet. A rename on the same volume, so it's instant; anything that fails
    /// is left where it was. Run only for the standard folders, never a `RELOAD_DATA_DIR` one.
    /// The Keychain token moves on first read (`KeychainStore.get`).
    @discardableResult
    public static func moveFolders(
        to directories: AppDirectories = .standard(),
        from legacy: AppDirectories = .standard(bundleID: legacyBundleID)
    ) -> [URL] {
        let fm = FileManager.default
        var moved: [URL] = []
        for (old, new) in [(legacy.applicationSupport, directories.applicationSupport), (legacy.caches, directories.caches)] {
            guard fm.fileExists(atPath: old.path(percentEncoded: false)),
                  !fm.fileExists(atPath: new.path(percentEncoded: false)) else { continue }
            try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: old, to: new)) != nil { moved.append(new) }
        }
        return moved
    }
}
