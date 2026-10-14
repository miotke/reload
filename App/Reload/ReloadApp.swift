import AddonKit
import AppKit
import SwiftUI

@main
struct ReloadApp: App {
    private static let environment = AppEnvironment.current()
    @State private var model = AppModel(
        manager: environment.manager, offersCommandLineTool: environment.offersCommandLineTool,
        usesStandardDefaults: environment.usesStandardDefaults)

    @AppStorage(SettingsKey.showMenuBarExtra) private var showMenuBarExtra = false
    @AppStorage(SettingsKey.appearance) private var appearance: AppAppearance = .system
    @AppStorage(SettingsKey.appIcon) private var appIcon: AppIconChoice = .classic

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 480)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // Belt and braces next to the store watcher: pick up changes made while inactive.
                    Task {
                        await model.reload()
                        await model.reloadMetadataIfChanged()
                    }
                    model.refreshInBackground()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stopAutoRefresh()
                }
                .onChange(of: appearance, initial: true) { appearance.apply() }
                .onChange(of: appIcon, initial: true) { appIcon.apply() }
        }
        .defaultSize(width: 1300, height: 880)
        .commands {
            // SwiftUI adds File ▸ New with an item per WindowGroup. A second main window only
            // duplicates the first, and an add-on window needs an add-on, so they open from rows.
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .textEditing) {
                Button("Find Add-ons") { SearchFieldFocus.focus() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(before: .sidebar) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                Divider()
            }
            CommandMenu("Add-ons") {
                Button("Check for Updates") { model.checkForUpdates() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.current == nil || model.current?.queue.isRefreshing == true)
                Button("Update All") { model.updateAll() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled((model.current?.installed.updateCount ?? 0) == 0 || model.current?.queue.isUpdatingAll == true)
                Divider()
                Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Add Installation…") { model.addInstallationWithPanel() }
            }
        }

        WindowGroup("Add-on", id: AddonWindowID.sceneID, for: AddonWindowID.self) { $id in
            AddonWindow(model: model, id: id)
                .environment(model)
        }
        .defaultSize(width: 900, height: 800)

        // A single-instance window: SwiftUI lists it in the Window menu.
        Window("Network Activity", id: NetworkActivityView.windowID) {
            NetworkActivityView(activity: model.activity)
        }
        .defaultSize(width: 980, height: 520)
        .keyboardShortcut("a", modifiers: [.command, .option])

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContent()
                .environment(model)
        } label: {
            let count = model.totalUpdateCount
            Label(count > 0 ? "\(count)" : "Reload",
                  systemImage: count > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                .labelStyle(.titleAndIcon)
        }
    }
}

/// Menu shown by the optional menu bar extra.
private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.totalUpdateCount
        Text(count == 1 ? "1 update available" : "\(count) updates available")
        Button("Check for Updates") { model.checkForUpdates() }
        Button("Update All") { model.updateAll() }
            .disabled(count == 0)
        Divider()
        Button("Open Reload") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        Button("Quit Reload") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
