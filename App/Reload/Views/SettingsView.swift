import AddonKit
import AppKit
import SwiftUI

/// The Settings scene: toolbar tabs, each a grouped `Form` sized to its content, so the
/// window resizes per tab and takes the tab's name as its title (docs/app/settings.md).
struct SettingsView: View {
    var updater: AppUpdater?
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.settingsTab) private var tab: SettingsTab = .general
    @AppStorage(SettingsKey.appIcon) private var appIcon: AppIconChoice = .classic
    @State private var github = GitHubTokenModel(keychain: KeychainStore())
    @State private var gitHubStatus = GitHubStatusModel()

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            Tab(SettingsTab.general.title, systemImage: SettingsTab.general.systemImage, value: .general) {
                GeneralSettingsTab(installations: model.installations, selectedInstallationID: $model.selectedInstallationID,
                                   updater: updater)
            }
            Tab(SettingsTab.appearance.title, systemImage: SettingsTab.appearance.systemImage, value: .appearance) {
                AppearanceSettingsTab()
            }
            Tab(SettingsTab.sources.title, systemImage: SettingsTab.sources.systemImage, value: .sources) {
                SourcesSettingsTab(sources: model.sources, setSource: model.setSource, load: model.loadSources)
            }
            Tab(SettingsTab.github.title, systemImage: SettingsTab.github.systemImage, value: .github) {
                let manager = model.manager
                GitHubSettingsTab(token: github, status: gitHubStatus,
                                  tokenDidChange: {
                                      Task {
                                          await manager.tokenDidChange()
                                          await gitHubStatus.refresh(from: manager)
                                      }
                                  },
                                  watchStatus: { await gitHubStatus.watch(manager) })
            }
            Tab(SettingsTab.commandLine.title, systemImage: SettingsTab.commandLine.systemImage, value: .commandLine) {
                CommandLineSettingsTab(tool: model.commandLineTool)
            }
            Tab(SettingsTab.advanced.title, systemImage: SettingsTab.advanced.systemImage, value: .advanced) {
                AdvancedSettingsTab(directories: AppEnvironment.directories(),
                                    canResetFirstLaunch: model.remembersFirstLaunchSteps,
                                    resetFirstLaunch: model.resetFirstLaunchSteps)
            }
        }
        // The main window applies it at launch; this covers changes with no main window open.
        .onChange(of: appIcon) { appIcon.apply() }
    }
}

extension View {
    /// Every tab: a grouped form at the window's width, as tall as its content.
    func settingsTab() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: SettingsLayout.width)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum SettingsLayout {
    static let width: CGFloat = 520
}

struct GeneralSettingsTab: View {
    var installations: [Installation]
    @Binding var selectedInstallationID: Installation.ID?
    /// Nil in Debug builds, which never update themselves.
    var updater: AppUpdater?

    @AppStorage(SettingsKey.defaultChannel) private var defaultChannel: Channel = .stable
    @AppStorage(SettingsKey.checkForUpdatesOnLaunch) private var checkForUpdatesOnLaunch = true
    @AppStorage(SettingsKey.showMenuBarExtra) private var showMenuBarExtra = false
    @AppStorage(SettingsKey.dependencyPolicy) private var dependencyPolicy: DependencyPolicy = .ask
    @AppStorage(SettingsKey.warnBeforeRemovingDependencies) private var warnBeforeRemovingDependencies = true
    @AppStorage(SettingsKey.showOtherGames) private var showsOtherGames = false

    private static let checkHelp = "On launch, when the app becomes active, and every 2 hours. Check for Updates (⌘R) always works."

    var body: some View {
        Form {
            Section("Updates") {
                Picker("Default channel", selection: $defaultChannel) {
                    ForEach(Channel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $checkForUpdatesOnLaunch) {
                    Text("Check for updates automatically")
                    Text(Self.checkHelp)
                }
                .help(Self.checkHelp)
            }

            if installations.count > 1 {
                Section {
                    Picker("Default installation", selection: $selectedInstallationID) {
                        ForEach(installations) { installation in
                            Text(installation.displayName).tag(Optional(installation.id))
                        }
                    }
                } header: {
                    Text("Installation")
                } footer: {
                    SettingsFootnote("The game the main window shows. Also in the window's title menu.")
                }
            }

            Section {
                Picker("When an add-on needs another add-on", selection: $dependencyPolicy) {
                    ForEach(DependencyPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("dependency-policy")
                Toggle("Warn before removing an add-on others need", isOn: $warnBeforeRemovingDependencies)
            } header: {
                Text("Dependencies")
            } footer: {
                SettingsFootnote("Some add-ons only load with another one installed, like LittleWigs with BigWigs. Installed shows what's missing either way; Reload only installs an add-on it's sure provides it.")
            }

            Section {
                Toggle("Show add-ons for other games", isOn: $showsOtherGames)
            } header: {
                Text("Browse")
            } footer: {
                SettingsFootnote("Off, Browse and search hide add-ons that won't load on the selected game, like Classic-only ones on Forever. Add-ons not checked yet, and Retail builds that may work on Forever, always show.")
            }

            Section("Menu Bar") {
                Toggle("Show update count in the menu bar", isOn: $showMenuBarExtra)
            }

            if let updater {
                ReloadUpdatesSection(updater: updater)
            }
        }
        .settingsTab()
    }
}

/// Reload's own updates, through Sparkle (docs/app/updates.md).
struct ReloadUpdatesSection: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Section {
            Toggle("Check for Reload updates automatically", isOn: $updater.automaticallyChecks)
            LabeledContent {
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } label: {
                Text("Version \(AppInfo.version)")
            }
        } header: {
            Text("Reload")
        } footer: {
            SettingsFootnote("Once a day. New versions download from GitHub and are checked against Reload's signing key before they install.")
        }
    }
}

struct AdvancedSettingsTab: View {
    var directories: AppDirectories
    var canResetFirstLaunch: Bool
    var resetFirstLaunch: () -> Void

    @State private var isConfirmingReset = false
    @State private var didReset = false

    var body: some View {
        Form {
            Section("Folders") {
                FolderRow(title: "Data folder", url: directories.applicationSupport)
                FolderRow(title: "Caches folder", url: directories.caches)
            }

            Section {
                LabeledContent {
                    Button("Reset…") { isConfirmingReset = true }
                        .disabled(!canResetFirstLaunch)
                } label: {
                    Text("Reset first-launch steps")
                    Text(resetDetail)
                }
            } header: {
                Text("First Launch")
            }
        }
        .settingsTab()
        .confirmationDialog("Reset first-launch steps?", isPresented: $isConfirmingReset) {
            Button("Reset") {
                resetFirstLaunch()
                didReset = true
            }
        } message: {
            Text("The next time Reload opens, it gathers add-on details again and offers to install reload if it isn't installed.")
        }
    }

    private var resetDetail: String {
        if !canResetFirstLaunch { return "Not remembered when RELOAD_DATA_DIR is set, so there's nothing to reset." }
        if didReset { return "Done. They'll appear the next time Reload opens." }
        return "Shows the add-on details sheet and the reload offer again on the next launch."
    }
}

/// A folder with its path and a button that opens it in Finder.
private struct FolderRow: View {
    var title: String
    var url: URL

    var body: some View {
        LabeledContent {
            Button("Show in Finder", action: show)
                .help("Show \(title.lowercased()) in Finder")
        } label: {
            Text(title)
            Text(url.path(percentEncoded: false))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func show() {
        let url = url
        Task {
            // A fresh install may not have created its caches yet.
            try? await Task.detached { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }.value
            NSWorkspace.shared.open(url)
        }
    }
}

/// Caption text under a settings section.
struct SettingsFootnote: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
