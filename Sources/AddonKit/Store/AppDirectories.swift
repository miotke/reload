import Foundation

/// Where the app keeps its own data. Inject a custom value in tests so nothing touches
/// the real `~/Library` folders.
public struct AppDirectories: Sendable, Hashable {
    /// `~/Library/Application Support/<bundle-id>` in production.
    public var applicationSupport: URL
    /// `~/Library/Caches/<bundle-id>` in production.
    public var caches: URL

    public init(applicationSupport: URL, caches: URL) {
        self.applicationSupport = applicationSupport
        self.caches = caches
    }

    /// Both folders under one root (`<root>/Application Support`, `<root>/Caches`). Handy for tests.
    public init(root: URL) {
        self.init(
            applicationSupport: root.appending(path: "Application Support", directoryHint: .isDirectory),
            caches: root.appending(path: "Caches", directoryHint: .isDirectory)
        )
    }

    /// The real per-user folders for `bundleID`. Nothing is created on disk.
    public static func standard(bundleID: String = AppInfo.bundleID) -> AppDirectories {
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appending(path: "Library", directoryHint: .isDirectory)
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? library.appending(path: "Application Support", directoryHint: .isDirectory)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? library.appending(path: "Caches", directoryHint: .isDirectory)
        return AppDirectories(
            applicationSupport: support.appending(path: bundleID, directoryHint: .isDirectory),
            caches: caches.appending(path: bundleID, directoryHint: .isDirectory)
        )
    }

    /// `<appSupport>/installations`, one JSON file per installation.
    public var installationsDirectory: URL {
        applicationSupport.appending(path: "installations", directoryHint: .isDirectory)
    }

    /// `<caches>/downloads`, cached release archives.
    public var downloadsDirectory: URL {
        caches.appending(path: "downloads", directoryHint: .isDirectory)
    }

    /// `<caches>/screenshots`, the app's screenshot `URLCache`. Inside Caches, so clearing
    /// caches (app or `addonctl cache clear`) includes it, and `ADDONS_DATA_DIR` moves it.
    public var screenshotsDirectory: URL {
        caches.appending(path: "screenshots", directoryHint: .isDirectory)
    }
}
