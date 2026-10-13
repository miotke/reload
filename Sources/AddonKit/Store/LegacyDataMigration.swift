import Foundation

/// Earlier bundle IDs: the ForeverAddons name (decision 0024) and Reload's own first ID,
/// which carried a personal name (decision 0026). This moves their data across once. The
/// old IDs stay here only so existing installs can find their data.
public enum LegacyDataMigration {
    /// Newest first, so the most recent data wins when more than one exists.
    public static let legacyBundleIDs = ["com.andrewmiotke.Reload", "com.andrewmiotke.ForeverAddons"]

    /// Moves the first legacy Application Support and Caches folders found to `directories`
    /// when the new ones don't exist yet. A rename on the same volume, so it's instant; anything
    /// that fails is left where it was. Run only for the standard folders, never a
    /// `RELOAD_DATA_DIR` one. The Keychain token moves on first read (`KeychainStore.get`).
    @discardableResult
    public static func moveFolders(
        to directories: AppDirectories = .standard(),
        from legacy: [AppDirectories] = legacyBundleIDs.map { .standard(bundleID: $0) }
    ) -> [URL] {
        let fm = FileManager.default
        var moved: [URL] = []
        for old in legacy {
            for (from, to) in [(old.applicationSupport, directories.applicationSupport), (old.caches, directories.caches)] {
                guard fm.fileExists(atPath: from.path(percentEncoded: false)),
                      !fm.fileExists(atPath: to.path(percentEncoded: false)) else { continue }
                try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fm.moveItem(at: from, to: to)) != nil { moved.append(to) }
            }
        }
        return moved
    }
}
