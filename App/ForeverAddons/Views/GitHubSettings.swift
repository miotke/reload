import SwiftUI

/// Settings ▸ GitHub: the Keychain token, and which token is in use.
struct GitHubSettingsTab: View {
    var token: GitHubTokenModel
    /// Tells the manager to pick up a changed Keychain token.
    var tokenDidChange: () -> Void

    private static let tokensHelp = URL(string: "https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens")!
    private static let newToken = URL(string: "https://github.com/settings/personal-access-tokens/new")!

    var body: some View {
        @Bindable var token = token
        Form {
            Section {
                SecureField("Personal access token", text: $token.token, prompt: Text("ghp_…"))
                HStack {
                    if let error = token.error {
                        RowErrorText(message: error)
                    } else if let message = token.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { if token.remove() { tokenDidChange() } }
                        .disabled(!token.hasKeychainToken)
                    Button("Save") { if token.save() { tokenDidChange() } }
                        .disabled(!token.canSave)
                }
            } header: {
                Text("Personal Access Token")
            } footer: {
                SettingsFootnote("Optional. A token raises GitHub's rate limits for search and update checks. It's stored in your Keychain and needs no scopes.")
            }

            Section {
                LabeledContent("Token in use", value: token.source.description)
            } header: {
                Text("Status")
            } footer: {
                if let variable = token.environmentVariable {
                    SettingsFootnote("\(variable) is set in this app's environment, so it's used instead of any Keychain token.")
                }
            }

            Section {
                Link("About personal access tokens", destination: Self.tokensHelp)
                Link("Create a token on GitHub", destination: Self.newToken)
            }
        }
        .settingsTab()
        .onAppear(perform: token.load)
    }
}
