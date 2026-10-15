import AddonKit
import SwiftUI

/// Settings ▸ Sources: which sources search and Browse use (docs/features/sources.md).
struct SourcesSettingsTab: View {
    var sources: [SourceSetting]
    var setSource: (SourceID, Bool) -> Void
    /// Re-reads the stored settings, which `reload sources` may have changed.
    var load: () async -> Void

    var body: some View {
        Form {
            Section {
                ForEach(sources) { setting in
                    Toggle(isOn: Binding(get: { setting.isEnabled }, set: { setSource(setting.source, $0) })) {
                        Text(setting.source.displayName)
                        Text(Self.summary(setting.source))
                    }
                    // For the UI tests (App/ReloadUITests).
                    .accessibilityIdentifier("source-\(setting.source.rawValue)")
                }
            } header: {
                Text("Search and Browse")
            } footer: {
                SettingsFootnote("Add-ons from a source that's off don't appear in search or Browse. Ones you've already installed from it stay installed and keep getting updates.")
            }
        }
        .settingsTab()
        .task { await load() }
    }

    static func summary(_ source: SourceID) -> String {
        switch source {
        case .github: "Add-ons published as GitHub releases, from the community catalogue"
        case .wowinterface: "Thousands of add-ons from wowinterface.com"
        case .tukui: "ElvUI and Tukui from tukui.org"
        }
    }
}
