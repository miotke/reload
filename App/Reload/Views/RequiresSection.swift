import AddonKit
import SwiftUI

/// The inspector's "Requires" section: required add-ons the game won't load this one
/// without, each with a way to get it (docs/app/required-addons.md). The core's
/// `suggested` candidate gets one Install button; otherwise every candidate is listed, and
/// with none, Search opens Browse with the folder name.
struct RequiresSection: View {
    var queue: UpdateQueue
    var name: String
    var missing: [MissingDependency]
    /// Opens Browse searching for the text; nil where there's no main window to switch.
    var search: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Requires").font(.headline)
            Text("The game won't load \(name) until \(missing.count == 1 ? "this is" : "these are") installed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(missing) { dependency in
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(dependency.folder).fontWeight(.medium)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .help("\(dependency.folder) isn't in Interface/AddOns")
                    providers(dependency)
                        .padding(.leading, 22)
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder private func providers(_ dependency: MissingDependency) -> some View {
        if let suggested = dependency.suggested {
            VStack(alignment: .leading, spacing: 4) {
                DependencyInstallButton(queue: queue, candidate: suggested, title: "Install \(suggested.name)",
                                        rowState: queue.row(suggested.ref.description))
                Text(suggested.reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !dependency.candidates.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(dependency.candidates, id: \.ref) { candidate in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name)
                            Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        DependencyInstallButton(queue: queue, candidate: candidate, title: "Install",
                                                rowState: queue.row(candidate.ref.description))
                            .accessibilityLabel("Install \(candidate.name)")
                    }
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("No add-on in the catalogue provides it.").foregroundStyle(.secondary)
                Spacer()
                if let search {
                    Button("Search") { search(dependency.folder) }
                        .controlSize(.small)
                        .help("Search Browse for \(dependency.folder)")
                }
            }
        }
    }
}

/// Installs one candidate through the queue, so its progress and errors show like any
/// install. Separate so download ticks re-render only this button.
private struct DependencyInstallButton: View {
    @AppStorage(SettingsKey.defaultChannel) private var defaultChannel: Channel = .stable
    var queue: UpdateQueue
    var candidate: DependencyCandidate
    var title: String
    var rowState: RowState

    var body: some View {
        HStack(spacing: 6) {
            if let activity = rowState.activity {
                ActivityIndicator(activity: activity)
            } else {
                Button(title) { Task { await queue.install(candidate.ref, channel: defaultChannel) } }
                    .controlSize(.small)
                    .help("Install \(candidate.name) from \(candidate.ref.sourceName)")
            }
            if let error = rowState.error { RowErrorIcon(message: error) }
        }
    }
}
