import AddonKit
import SwiftUI

/// Support badge for search results, naming the installation's game.
struct SupportBadge: View {
    var status: SupportStatus
    var flavor: Flavor

    var body: some View {
        // Not checked is an absence of information, not a verdict, so it gets no capsule.
        let isPlain = status == .unknown
        Text(SupportLabel.text(for: status, flavor: flavor))
            .font(.caption.weight(isPlain ? .regular : .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isPlain ? Color.clear : color.opacity(0.12), in: Capsule())
            .help(SupportLabel.help(for: status, flavor: flavor))
            .accessibilityLabel(SupportLabel.help(for: status, flavor: flavor))
    }

    private var color: Color {
        switch status {
        case .supported: .green
        case .checking, .unknown, .needsDownload: .secondary
        case .unsupported, .noReleases: .orange
        }
    }

    /// Results whose support isn't confirmed are shown dimmed.
    static func isDimmed(_ status: SupportStatus) -> Bool {
        if case .supported = status { false } else if case .checking = status { false } else { true }
    }
}

/// Spinner / progress bar shown in a row's action column while work is in flight.
struct ActivityIndicator: View {
    var activity: RowActivity
    /// Table cells are narrow: there the label moves to the tooltip.
    var showsLabel = true

    var body: some View {
        HStack(spacing: 6) {
            if let fraction = activity.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
            } else {
                ProgressView().controlSize(.small)
            }
            if showsLabel {
                Text(activity.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(activity.label)
    }
}

/// Small warning icon for a row error; the message is in the tooltip and the inspector.
struct RowErrorIcon: View {
    var message: String

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .help(message)
            .accessibilityLabel(message)
    }
}

/// Progress of a metadata refresh: the bar and message under "Add Installation…".
struct RefreshStatusView: View {
    var progress: RefreshProgress
    var installation: Installation
    var showsInstallation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
            Text(progress.displayMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(showsInstallation ? "\(installation.displayName): \(progress.displayMessage)" : progress.displayMessage)
        .accessibilityElement(children: .combine)
    }
}

extension RefreshProgress {
    /// The core's message, or a phase description when it sends none.
    var displayMessage: String {
        if !message.isEmpty { return message }
        return switch phase {
        case .catalogue: "Downloading the add-on catalogue…"
        case .updates: "Checking for updates…"
        case .support: "Checking support…"
        case .finished: "Done"
        }
    }
}

/// Inline error under a row.
struct RowErrorText: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
            .textSelection(.enabled)
    }
}

/// Non-blocking banner at the top of the detail area.
struct BannerView: View {
    var banner: Banner
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(banner.isError ? .orange : .accentColor)
            Text(banner.message)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
