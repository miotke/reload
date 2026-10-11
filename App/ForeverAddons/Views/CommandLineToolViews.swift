import SwiftUI

/// One-time offer, shown after the main window first appears, to link `addonctl` into
/// `/usr/local/bin`.
struct CommandLineToolOfferSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var tool: CommandLineToolModel { model.commandLineTool }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Install the \(Text("addonctl").font(.title3.monospaced())) command-line tool?")
                        .font(.title3.weight(.semibold))
                    Text("Manage the same add-ons from Terminal, for example to update everything:")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("$ addonctl update")
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("Creates a link at \(tool.linkPath). You'll be asked for an administrator password.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("You can install it later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if tool.isWorking { ProgressView().controlSize(.small) }
                Button("Not Now", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install", action: install)
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(tool.isWorking)
        }
        .padding(20)
        .frame(width: 440)
    }

    private func install() {
        Task {
            let error = await tool.install()
            dismiss()
            switch error {
            case nil:
                model.banner = Banner(message: "Installed addonctl at \(tool.linkPath).", isError: false)
            case CLIInstaller.Failure.cancelled?:
                model.banner = Banner(message: "addonctl wasn't installed. You can install it later in Settings.", isError: false)
            case let error?:
                model.banner = Banner(message: "Couldn't install addonctl: \(error.localizedDescription) You can try again in Settings.")
            }
        }
    }
}

/// Settings section: status of the `addonctl` link with Install / Repair / Uninstall.
struct CommandLineToolSection: View {
    @Environment(AppModel.self) private var model

    private var tool: CommandLineToolModel { model.commandLineTool }

    var body: some View {
        Section {
            LabeledContent("Status") {
                Text(statusText)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            HStack {
                if let message = tool.message {
                    if tool.messageIsError {
                        RowErrorText(message: message)
                    } else {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if tool.isWorking { ProgressView().controlSize(.small) }
                Button("Uninstall", role: .destructive) { Task { await tool.uninstall() } }
                    .disabled(!canUninstall || tool.isWorking)
                Button(installTitle) { Task { await tool.install() } }
                    .disabled(tool.status == .installed || !tool.helperExists || tool.isWorking)
            }
        } header: {
            Text("Command-Line Tool")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("""
                    addonctl manages add-ons from Terminal using the same data as this app. \
                    Installing links \(tool.linkPath) to the copy inside ForeverAddons, so it \
                    updates with the app. Needs an administrator password.
                    """)
                #if DEBUG
                Text("Debug build: the tool lives in DerivedData (\(tool.helperPath)), so the link points there.")
                #endif
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { tool.refresh() }
    }

    private var statusText: String {
        switch tool.status {
        case .notInstalled: tool.helperExists ? "Not installed" : "Not available in this build"
        case .installed: "Installed at \(tool.linkPath)"
        case .otherCopy(let target): "Installed, but points to another copy of the app (\(target))"
        case .foreign(let target?): "\(tool.linkPath) points to \(target)"
        case .foreign(nil): "Another file exists at \(tool.linkPath)"
        }
    }

    private var installTitle: String {
        switch tool.status {
        case .otherCopy: "Repair"
        case .foreign: "Replace"
        case .notInstalled, .installed: "Install"
        }
    }

    private var canUninstall: Bool {
        switch tool.status {
        case .installed, .otherCopy: true
        case .notInstalled, .foreign: false
        }
    }
}

#Preview("Offer") {
    CommandLineToolOfferSheet()
        .environment(AppModel(manager: MockAddonManager(latency: 0)))
}
