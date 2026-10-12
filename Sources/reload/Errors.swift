import AddonKit
import ArgumentParser
import Foundation

/// Errors raised by the CLI itself (as opposed to `AddonError` from the core).
enum CLIError: Error, Equatable, LocalizedError {
    case usage(String)
    case ambiguousReference(String, [AddonRef])
    case referenceNotFound(String)
    case noInstallations
    case ambiguousInstallation([Installation])
    case installationNotFound(String)
    /// A destructive action ran without `--yes` and couldn't prompt.
    case confirmationRequired(String)
    case cancelled
    /// Some, but not all, items of a batch failed (messages were already printed).
    case partialFailure(failed: Int, total: Int)
    /// Every item of a batch failed with the same exit code.
    case allFailed(count: Int, exitCode: Int32)
    case general(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            message
        case .ambiguousReference(let input, let candidates):
            "\"\(input)\" matches several add-ons; use one of:\n" + candidates.map { "  \(Format.ref($0))" }.joined(separator: "\n")
        case .referenceNotFound(let input):
            "No add-on named \"\(input)\". Try `reload search \(input)` or use owner/repo."
        case .noInstallations:
            "No World of Warcraft installation found. Add one with `reload installs add <path>`."
        case .ambiguousInstallation(let installations):
            "Several installations found; pick one with --install <id> or `reload installs default <id>`:\n"
                + installations.map { "  \($0.id)  \($0.flavor.displayName)  \($0.root.path(percentEncoded: false))" }.joined(separator: "\n")
        case .installationNotFound(let value):
            "No installation matches \"\(value)\". See `reload installs`."
        case .confirmationRequired(let action):
            "\(action) needs confirmation; pass --yes to proceed without a prompt."
        case .cancelled:
            "Cancelled."
        case .partialFailure(let failed, let total):
            "\(failed) of \(total) add-ons failed."
        case .allFailed(let count, _):
            count == 1 ? "The operation failed." : "All \(count) add-ons failed."
        case .general(let message):
            message
        }
    }
}

/// docs/cli/commands.md exit codes.
enum ExitStatus {
    static let success: Int32 = 0
    static let general: Int32 = 1
    static let usage: Int32 = 2
    static let partialFailure: Int32 = 3
    static let rateLimited: Int32 = 4
    static let conflict: Int32 = 5
    static let outdated: Int32 = 10

    static func code(for error: any Error) -> Int32 {
        switch error {
        case let error as AddonError:
            switch error {
            case .rateLimited: return rateLimited
            case .folderConflict, .unmanagedFolderExists: return conflict
            case .invalidReference: return usage
            default: return general
            }
        case let error as CLIError:
            switch error {
            case .usage, .ambiguousReference, .ambiguousInstallation, .installationNotFound, .confirmationRequired:
                return usage
            case .partialFailure: return partialFailure
            case .allFailed(_, let code): return code
            case .referenceNotFound, .noInstallations, .cancelled, .general:
                return general
            }
        case let error as ExitCode:
            return error.rawValue
        case is ValidationError:
            return usage
        default:
            return general
        }
    }

    /// Stable identifier for `{"error": {"code": …}}`.
    static func identifier(for error: any Error) -> String {
        switch error {
        case let error as AddonError:
            switch error {
            case .invalidReference: "invalid_reference"
            case .notFound: "not_found"
            case .noCompatibleRelease: "no_compatible_release"
            case .rateLimited: "rate_limited"
            case .http: "http_error"
            case .invalidArchive: "invalid_archive"
            case .unsafeArchivePath: "unsafe_archive"
            case .folderConflict: "folder_conflict"
            case .unmanagedFolderExists: "unmanaged_folder"
            case .notInstalled: "not_installed"
            case .noRollbackAvailable: "no_rollback"
            case .installationNotFound: "installation_not_found"
            case .cannotRemove: "cannot_remove"
            }
        case let error as CLIError:
            switch error {
            case .usage: "usage"
            case .ambiguousReference: "ambiguous_reference"
            case .referenceNotFound: "not_found"
            case .noInstallations: "no_installation"
            case .ambiguousInstallation: "ambiguous_installation"
            case .installationNotFound: "installation_not_found"
            case .confirmationRequired: "confirmation_required"
            case .cancelled: "cancelled"
            case .partialFailure: "partial_failure"
            case .allFailed: "failed"
            case .general: "error"
            }
        case is ValidationError: "usage"
        case is URLError: "network"
        default: "error"
        }
    }

    /// The message shown to the user, with a hint where one helps.
    static func message(for error: any Error) -> String {
        switch error {
        case AddonError.unmanagedFolderExists(let folder):
            "\(folder) already exists and isn't managed. Retry with --force to overwrite it, or use `reload adopt`."
        case AddonError.folderConflict(let folder, let owner):
            "\(folder) is already installed by \(Format.ref(owner)). Remove that add-on first."
        case AddonError.rateLimited(let reset):
            if let reset {
                "GitHub rate limit reached; try again \(reset.formatted(.relative(presentation: .named))). Set a token with `reload config set github-token` for a higher limit."
            } else {
                "GitHub rate limit reached. Set a token with `reload config set github-token` for a higher limit."
            }
        case let error as ValidationError:
            error.message
        case let error as LocalizedError:
            error.errorDescription ?? String(describing: error)
        default:
            (error as NSError).localizedDescription
        }
    }

    /// The error for a batch where `failures` of `total` items failed, or nil if none did.
    /// When everything failed for the same reason, that reason's code is kept (e.g. 5 for
    /// a conflict); otherwise the result is a partial failure (exit 3).
    static func batchError(failures: [any Error], total: Int) -> (any Error)? {
        guard !failures.isEmpty else { return nil }
        let codes = Set(failures.map(code(for:)))
        if failures.count == total, codes.count == 1 {
            return failures.count == 1 ? failures[0] : CLIError.allFailed(count: failures.count, exitCode: codes.first!)
        }
        return CLIError.partialFailure(failed: failures.count, total: total)
    }
}
