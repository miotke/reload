import AddonKit
import Foundation
import Observation

/// Progress of a long-running operation on one row.
enum RowActivity: Equatable {
    case queued
    case downloading(Double)
    case installing
    /// Generic in-flight work (rollback, uninstall, adopt…).
    case working(String)

    var label: String {
        switch self {
        case .queued: "Queued"
        case .downloading: "Downloading…"
        case .installing: "Installing…"
        case .working(let label): label
        }
    }

    var fraction: Double? {
        if case .downloading(let value) = self { value } else { nil }
    }
}

/// Per-row progress and errors. One object per row, so a download progress tick re-renders
/// only the cells (and inspector controls) that read that row, not every row in the table.
@Observable @MainActor
final class RowState {
    var activity: RowActivity?
    var error: String?
    /// An install failed because an unmanaged folder is in the way; retry needs `force`.
    var needsOverwrite = false
}

/// Progress of the running refresh, kept apart from the installation's other models so only
/// the sidebar bar and the first-launch sheet re-render on each progress event.
@Observable @MainActor
final class RefreshStatus {
    /// Latest event; nil when no refresh is running or it hasn't reported yet. Set by `UpdateQueue`.
    var progress: RefreshProgress?

    /// For the sidebar: throttled refreshes that finish at once never report a phase, so
    /// they don't flash the bar.
    var visibleProgress: RefreshProgress? {
        guard let progress, progress.phase != .finished else { return nil }
        return progress
    }
}
