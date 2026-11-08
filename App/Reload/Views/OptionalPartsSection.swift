import AddonKit
import SwiftUI

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
