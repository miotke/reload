import SwiftUI

/// Settings ▸ GitHub: the Keychain token, which token is in use, and the rate limits.
struct GitHubSettingsTab: View {
    var token: GitHubTokenModel
    var status: GitHubStatusModel
    /// Tells the manager to pick up a changed Keychain token, then reloads `status`.
    var tokenDidChange: () -> Void
    /// Keeps `status` current while the tab is visible; returns when cancelled.
    var watchStatus: () async -> Void

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
                let display = status.display
                if let warning = display.pauseWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                GitHubQuotaRow(title: "API requests", quota: display.api)
                GitHubQuotaRow(title: "Searches", quota: display.search)
            } header: {
                Text("Rate Limits")
            } footer: {
                SettingsFootnote("Browsing and update checks mostly use quota-free requests, so these limits rarely get in the way.")
            }

            Section {
                Link("About personal access tokens", destination: Self.tokensHelp)
                Link("Create a token on GitHub", destination: Self.newToken)
            }
        }
        .settingsTab()
        .onAppear(perform: token.load)
        .task { await watchStatus() }
    }
}

/// "API requests · Resets in 23 min" with "42 of 60 left" and a capacity bar.
struct GitHubQuotaRow: View {
    var title: String
    var quota: GitHubQuotaDisplay

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(quota.value)
                    .monospacedDigit()
                    .foregroundStyle(quota.isExhausted ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if let fraction = quota.fraction {
                    Gauge(value: fraction) { EmptyView() }
                        .gaugeStyle(.linearCapacity)
                        .tint(quota.isExhausted ? .orange : .accentColor)
                        .frame(width: 80)
                        .accessibilityLabel(title)
                }
            }
        } label: {
            Text(title)
            Text(quota.detail)
        }
    }
}
