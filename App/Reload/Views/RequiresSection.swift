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

/// The inspector's "Optional Parts" section: extra add-ons from the same repo that this one
/// can use, such as voice packs (docs/app/optional-parts.md). Shown only when the core
/// reports some. Nothing installs unless the user clicks: parts can be over 1 GB.
struct OptionalPartsSection: View {
    var queue: UpdateQueue
    var list: OptionalPartsList
    var name: String

    var body: some View {
        if !list.rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("Optional Parts").font(.headline)
                Text("Extra add-ons from \(name)'s repository that it can use. Reload only installs them when you ask.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = list.error { RowErrorText(message: "Couldn't check optional parts: \(error)") }
                ForEach(list.rows) { row in
                    OptionalPartRowView(queue: queue, row: row, rowState: queue.row(row.rowID))
                }
            }
            .font(.callout)
        }
    }
}

/// One part and its action. Separate so download ticks re-render only this row.
private struct OptionalPartRowView: View {
    @AppStorage(SettingsKey.defaultChannel) private var defaultChannel: Channel = .stable
    var queue: UpdateQueue
    var row: OptionalPartRow
    var rowState: RowState

    @State private var confirmManage = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).fontWeight(.medium).textSelection(.enabled)
                Text(row.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: 6) {
                if let error = rowState.error { RowErrorIcon(message: error) }
                if let activity = rowState.activity {
                    ActivityIndicator(activity: activity)
                } else {
                    action
                }
            }
        }
        .confirmationDialog("Manage \(row.name) with Reload?", isPresented: $confirmManage) {
            Button("Download and Manage") {
                Task { _ = await queue.adopt(folder: row.part.folder, as: row.part.ref) }
            }
        } message: {
            Text(row.manageMessage)
        }
    }

    @ViewBuilder private var action: some View {
        switch row.action {
        case .install:
            Button(row.actionTitle) { Task { await queue.install(row.part.ref, channel: defaultChannel) } }
                .controlSize(.small)
                .help(row.actionHelp)
                .accessibilityLabel("Install \(row.name)")
        case .manage:
            Button(row.actionTitle) { confirmManage = true }
                .controlSize(.small)
                .help(row.actionHelp)
                .accessibilityLabel("Manage \(row.name)")
        case .installed:
            Label {
                Text(row.actionTitle).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .labelStyle(.titleAndIcon)
            .help(row.actionHelp)
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
