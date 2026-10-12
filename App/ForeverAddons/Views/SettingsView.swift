import AddonKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.defaultChannel) private var defaultChannel: Channel = .stable
    @AppStorage(SettingsKey.checkForUpdatesOnLaunch) private var checkForUpdatesOnLaunch = true
    @AppStorage(SettingsKey.showMenuBarExtra) private var showMenuBarExtra = false

    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var tokenMessage: String?
    @State private var tokenError: String?

    private let keychain = KeychainStore()

    var body: some View {
        Form {
            Section {
                SecureField("Personal access token", text: $token, prompt: Text("ghp_…"))
                HStack {
                    if let tokenError {
                        RowErrorText(message: tokenError)
                    } else if let tokenMessage {
                        Text(tokenMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive, action: removeToken)
                        .disabled(!hasStoredToken)
                    Button("Save", action: saveToken)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("GitHub")
            } footer: {
                Text("Optional. A token raises GitHub's rate limits for search and update checks. It's stored in your Keychain and needs no scopes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Picker("Default channel", selection: $defaultChannel) {
                    ForEach(Channel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Check for updates automatically", isOn: $checkForUpdatesOnLaunch)
                    .help("On launch, when the app becomes active, and every 2 hours. Check for Updates (⌘R) always works.")
            }

            Section("Menu Bar") {
                Toggle("Show update count in the menu bar", isOn: $showMenuBarExtra)
            }

            CommandLineToolSection()
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: loadToken)
    }

    private func loadToken() {
        let stored = keychain.get()
        hasStoredToken = stored != nil
        token = stored ?? ""
        tokenMessage = stored == nil ? "No token saved." : "Token saved in Keychain."
    }

    private func saveToken() {
        do {
            try keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines))
            tokenError = nil
            hasStoredToken = true
            tokenMessage = "Token saved in Keychain."
            Task { await model.manager.tokenDidChange() }
        } catch {
            tokenError = error.localizedDescription
        }
    }

    private func removeToken() {
        do {
            try keychain.delete()
            token = ""
            tokenError = nil
            hasStoredToken = false
            tokenMessage = "Token removed."
            Task { await model.manager.tokenDidChange() }
        } catch {
            tokenError = error.localizedDescription
        }
    }
}
