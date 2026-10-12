import AddonKit
import SwiftUI

/// The R / F / C bubbles (docs/app/layout.md#games). Reads only its pre-computed model, so
/// it's cheap in table cells and never touches the environment.
struct GameBubbles: View {
    var model: GameBubblesModel

    var body: some View {
        if let bubbles = model.bubbles {
            HStack(spacing: 3) {
                ForEach(bubbles) { bubble in
                    GameBubble(family: bubble.family, isPresent: bubble.isPresent, isOwn: bubble.isOwn)
                        .help(bubble.help)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)
        } else {
            Text("—")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help(model.uncheckedHelp)
                .accessibilityLabel(model.accessibilityLabel)
        }
    }
}

/// One capsule. Present: tinted, or filled for the installation's own family; absent: a faint
/// outline in the same slot.
struct GameBubble: View {
    var family: GameFamily
    var isPresent: Bool
    var isOwn: Bool

    static func color(_ family: GameFamily) -> Color {
        switch family {
        case .retail: .blue
        case .forever: .teal
        case .classic: .orange
        }
    }

    var body: some View {
        let color = Self.color(family)
        Text(family.letter)
            .font(.caption2.weight(isOwn && isPresent ? .bold : .semibold))
            .foregroundStyle(isPresent ? (isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(color)) : AnyShapeStyle(.quaternary))
            .frame(width: 18, height: 15)
            .background {
                if isPresent {
                    Capsule().fill(color.opacity(isOwn ? 0.9 : 0.18))
                }
            }
            .overlay {
                if !isPresent { Capsule().strokeBorder(.quaternary, lineWidth: 1) }
            }
    }
}

/// "R Retail · F Forever · C Classic" in the Browse status bar; letters only when narrow.
struct GameLegend: View {
    var flavor: Flavor

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(GameFamily.allCases, id: \.self) { family in
                    HStack(spacing: 3) {
                        GameBubble(family: family, isPresent: true, isOwn: family == flavor.family)
                        Text(family.displayName)
                    }
                }
            }
            HStack(spacing: 3) {
                ForEach(GameFamily.allCases, id: \.self) { family in
                    GameBubble(family: family, isPresent: true, isOwn: family == flavor.family)
                }
            }
            .help("R Retail · F Forever · C Classic")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Games: R Retail, F Forever, C Classic")
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
