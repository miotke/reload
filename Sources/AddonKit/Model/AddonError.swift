import Foundation

public enum AddonError: Error, Sendable, Equatable, LocalizedError {
    case invalidReference(String)
    case notFound(AddonRef)
    case noCompatibleRelease(AddonRef, Flavor)
    case rateLimited(resetAt: Date?)
    case http(status: Int, url: URL)
    case invalidArchive(String)
    case unsafeArchivePath(String)
    /// Folder `folder` is already owned by another managed add-on.
    case folderConflict(folder: String, owner: AddonRef)
    /// Folder exists on disk but no managed add-on owns it; retry with `force`.
    case unmanagedFolderExists(String)
    case notInstalled(AddonRef)
    case noRollbackAvailable(AddonRef)
    case installationNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidReference(let s): "Not a valid add-on reference: \(s)"
        case .notFound(let ref): "\(ref.identifier) was not found."
        case .noCompatibleRelease(let ref, let flavor): "\(ref.identifier) has no \(flavor.displayName) build yet."
        case .rateLimited(let reset):
            if let reset { "GitHub rate limit reached. Try again \(reset.formatted(.relative(presentation: .named)))." }
            else { "GitHub rate limit reached." }
        case .http(let status, let url): "HTTP \(status) from \(url.host() ?? url.absoluteString)."
        case .invalidArchive(let s): "Invalid add-on archive: \(s)"
        case .unsafeArchivePath(let p): "Archive contains an unsafe path: \(p)"
        case .folderConflict(let folder, let owner): "\(folder) is already installed by \(owner.identifier)."
        case .unmanagedFolderExists(let folder): "\(folder) already exists and isn't managed. Overwrite it?"
        case .notInstalled(let ref): "\(ref.identifier) isn't installed."
        case .noRollbackAvailable(let ref): "No previous version of \(ref.identifier) is cached."
        case .installationNotFound(let id): "Installation \(id) not found."
        }
    }
}
