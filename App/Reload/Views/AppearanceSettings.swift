import AppKit
import SwiftUI

/// Settings ▸ Appearance: Light / Dark / System cards and the app icon grid.
struct AppearanceSettingsTab: View {
    @AppStorage(SettingsKey.appearance) private var appearance: AppAppearance = .system
    @AppStorage(SettingsKey.appIcon) private var appIcon: AppIconChoice = .classic

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    ForEach([AppAppearance.light, .dark, .system]) { option in
                        AppearanceCard(appearance: option, isSelected: appearance == option) { appearance = option }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } header: {
                Text("Appearance")
            } footer: {
                SettingsFootnote("Also in View ▸ Appearance.")
            }

            Section {
                AppIconGrid(selection: $appIcon)
                    .padding(.vertical, 4)
            } header: {
                Text("App Icon")
            } footer: {
                SettingsFootnote("Changes the icon in the Dock and app switcher. Finder always shows the standard icon.")
            }
        }
        .settingsTab()
    }
}

extension AppAppearance {
    /// The card label; `title` is the menu's longer wording.
    var shortTitle: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// A selectable thumbnail like System Settings ▸ Appearance.
private struct AppearanceCard: View {
    var appearance: AppAppearance
    var isSelected: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                thumbnail
                    .frame(width: 96, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 1)
                    }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                    }
                Text(appearance.shortTitle)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appearance.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var thumbnail: some View {
        switch appearance {
        case .light: WindowThumbnail(isDark: false)
        case .dark: WindowThumbnail(isDark: true)
        case .system:
            ZStack {
                WindowThumbnail(isDark: false)
                WindowThumbnail(isDark: true)
                    .mask { HStack(spacing: 0) { Color.clear; Color.black } }
            }
        }
    }
}

/// A miniature desktop with a window, in fixed colours: it depicts a mode, so it
/// mustn't follow the current one.
private struct WindowThumbnail: View {
    var isDark: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: isDark ? [Color(white: 0.16), Color(red: 0.16, green: 0.2, blue: 0.4)]
                                          : [Color(red: 0.55, green: 0.75, blue: 0.95), Color(red: 0.75, green: 0.85, blue: 0.95)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 2.5) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 4, height: 4) }
                    Spacer()
                }
                .padding(.horizontal, 4)
                .frame(height: 9)
                .background(isDark ? Color(white: 0.24) : Color(white: 0.93))
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(0..<4, id: \.self) { _ in Capsule().fill(text.opacity(0.35)).frame(width: 12, height: 2.5) }
                    }
                    .padding(4)
                    .frame(width: 20, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(isDark ? Color(white: 0.2) : Color(white: 0.9))
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(Color.accentColor).frame(width: 28, height: 3)
                        ForEach(0..<3, id: \.self) { _ in Capsule().fill(text.opacity(0.25)).frame(width: 38, height: 2.5) }
                    }
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(isDark ? Color(white: 0.13) : .white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .padding(.leading, 12)
            .padding(.top, 10)
            .padding(.trailing, -8)
            .padding(.bottom, -8)
        }
    }

    private var text: Color { isDark ? .white : .black }
}

/// The six icons as large thumbnails with a selection ring and the name under each.
struct AppIconGrid: View {
    @Binding var selection: AppIconChoice

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(AppIconChoice.allCases) { choice in
                Button { selection = choice } label: {
                    VStack(spacing: 6) {
                        AppIconThumbnail(choice: choice)
                            .frame(width: 76, height: 76)
                            .padding(4)
                            .overlay {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .strokeBorder(selection == choice ? Color.accentColor : .clear, lineWidth: 3)
                            }
                        Text(choice.title)
                            .font(.callout)
                            .fontWeight(selection == choice ? .semibold : .regular)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(choice.title) icon")
                .accessibilityAddTraits(selection == choice ? .isSelected : [])
            }
        }
    }
}

/// The icon's artwork, or a labelled rounded square while the asset is missing.
private struct AppIconThumbnail: View {
    var choice: AppIconChoice

    var body: some View {
        if let image = choice.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            // macOS icon artwork leaves a margin around the rounded square; match it.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .top, endPoint: .bottom))
                .overlay {
                    Text(choice.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(7)
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
        }
    }

    private var tint: Color {
        switch choice {
        case .classic: .blue
        case .rune: .teal
        case .scroll: .brown
        case .gilded: .orange
        }
    }
}
