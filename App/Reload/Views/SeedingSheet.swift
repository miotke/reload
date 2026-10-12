import AddonKit
import SwiftUI

/// First launch: blocks the window while the first refresh downloads the catalogue and checks
/// installed add-ons, so the tables don't open half-empty. Closes itself when the refresh
/// finishes; after a few seconds it can be sent to the background, where the sidebar shows it.
struct SeedingSheet: View {
    var refresh: RefreshStatus
    var flavor: Flavor
    var continueInBackground: () -> Void

    @State private var canContinueInBackground = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Gathering Add-on Details")
                        .font(.title3.weight(.semibold))
                    Text("""
                        Reload is downloading the add-on catalogue and checking your add-ons \
                        for updates and \(flavor.displayName) support. This takes longer the first time.
                        """)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: refresh.progress?.fraction ?? 0)
                    .progressViewStyle(.linear)
                HStack {
                    Text(refresh.progress?.displayMessage ?? "Starting…")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let progress = refresh.progress, progress.total > 0 {
                        Text("\(progress.completed) of \(progress.total)")
                            .monospacedDigit()
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                // Always laid out so the sheet doesn't jump when it appears.
                Button("Continue in Background", action: continueInBackground)
                    .opacity(canContinueInBackground ? 1 : 0)
                    .disabled(!canContinueInBackground)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
        .task {
            try? await Task.sleep(for: .seconds(3))
            canContinueInBackground = true
        }
    }
}
