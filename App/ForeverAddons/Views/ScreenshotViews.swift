import SwiftUI

/// Horizontal strip of README screenshots. Click one to open the viewer.
struct ScreenshotGallery: View {
    var urls: [URL]
    /// Thumbnail frame; decoded at twice its width for Retina.
    var thumbnail = CGSize(width: 150, height: 96)

    @State private var viewing: Viewing?

    private struct Viewing: Identifiable {
        var index: Int
        var id: Int { index }
    }

    var body: some View {
        ScrollView(.horizontal) {
            // Lazy, so thumbnails load as the strip scrolls; each load is cancelled when its
            // thumbnail goes away (scrolled off or a different add-on selected).
            LazyHStack(spacing: 8) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    Button {
                        viewing = Viewing(index: index)
                    } label: {
                        ScreenshotImage(url: url, maxPixelSize: Int(thumbnail.width * 2))
                            .frame(width: thumbnail.width, height: thumbnail.height)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    }
                    .buttonStyle(.plain)
                    .help("Show screenshot \(index + 1) of \(urls.count)")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.automatic)
        .frame(height: thumbnail.height + 8)
        .sheet(item: $viewing) { viewing in
            ScreenshotViewer(urls: urls, index: viewing.index)
        }
    }
}

/// One screenshot loaded through `ScreenshotLoader`, filling its frame.
struct ScreenshotImage: View {
    var url: URL
    var maxPixelSize: Int
    var contentMode: ContentMode = .fill

    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case loaded(CGImage)
        case failed
    }

    var body: some View {
        ZStack {
            switch phase {
            case .loading:
                Rectangle().fill(.quaternary)
                ProgressView().controlSize(.small)
            case .loaded(let image):
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            case .failed:
                Rectangle().fill(.quaternary)
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: url) {
            phase = .loading
            do {
                phase = .loaded(try await ScreenshotLoader.shared.image(at: url, maxPixelSize: maxPixelSize))
            } catch {
                if !Task.isCancelled { phase = .failed }
            }
        }
    }
}

/// A larger look at the screenshots, with previous/next (also ← and →).
struct ScreenshotViewer: View {
    @Environment(\.dismiss) private var dismiss
    var urls: [URL]
    @State var index: Int

    var body: some View {
        VStack(spacing: 0) {
            ScreenshotImage(url: urls[index], maxPixelSize: 2000, contentMode: .fit)
                .frame(minWidth: 640, idealWidth: 960, minHeight: 400, idealHeight: 600)
                .background(.black.opacity(0.85))
            Divider()
            HStack {
                Button("Previous", systemImage: "chevron.left") { index -= 1 }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index == 0)
                Text("\(index + 1) of \(urls.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Next", systemImage: "chevron.right") { index += 1 }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index >= urls.count - 1)
                Spacer()
                Link("Open in Browser", destination: urls[index])
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .labelStyle(.iconOnly)
            .padding(12)
        }
        .onExitCommand { dismiss() }
    }
}
