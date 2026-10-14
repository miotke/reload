import AppKit
import SwiftUI

/// Window ▸ Network Activity: every request and download, newest first (docs/app/network-activity.md).
struct NetworkActivityView: View {
    static let windowID = "network-activity"

    var activity: NetworkActivityModel
    @State private var selection: Set<ActivityRow.ID> = []

    var body: some View {
        @Bindable var activity = activity
        Table(activity.visibleRows, selection: $selection) {
            TableColumn("Time") { row in Text(row.time).monospacedDigit() }
                .width(min: 60, ideal: 70, max: 90)
            TableColumn("Method") { row in Text(row.method) }
                .width(min: 40, ideal: 50, max: 70)
            TableColumn("Host") { row in Text(row.host).lineLimit(1) }
                .width(min: 80, ideal: 170)
            TableColumn("Path") { row in
                Text(row.path).lineLimit(1).truncationMode(.middle).help(row.url.absoluteString)
            }
            .width(min: 120, ideal: 320)
            TableColumn("Status") { row in
                Text(row.status).lineLimit(1)
                    .foregroundStyle(row.isFailure ? AnyShapeStyle(.red) : row.isRunning ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .help(row.status)
            }
            .width(min: 60, ideal: 110)
            TableColumn("Size") { row in Text(row.size).monospacedDigit() }
                .width(min: 50, ideal: 70, max: 100)
            TableColumn("Duration") { row in Text(row.duration).monospacedDigit() }
                .width(min: 50, ideal: 70, max: 100)
        }
        .contextMenu(forSelectionType: ActivityRow.ID.self) { ids in
            let urls = ids.compactMap { activity.row(id: $0)?.url.absoluteString }
            if !urls.isEmpty {
                Button(urls.count == 1 ? "Copy URL" : "Copy URLs") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
                }
            }
        }
        .overlay {
            if activity.visibleRows.isEmpty {
                ContentUnavailableView(
                    activity.downloadsOnly ? "No Downloads" : "No Network Activity", systemImage: "network",
                    description: Text(activity.downloadsOnly
                                      ? "Add-on downloads appear here as they happen."
                                      : "Requests appear here as Reload makes them."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $activity.downloadsOnly) {
                    Text("All").tag(false)
                    Text("Downloads").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Show every request, or only add-on downloads")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Clear", systemImage: "trash") { activity.clear() }
                    .help("Clear the list")
            }
        }
        .navigationSubtitle(activity.summary)
        .frame(minWidth: 640, minHeight: 280)
    }
}
