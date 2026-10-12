import AddonKit
import SwiftUI

/// Start managing an unmanaged folder from a GitHub repository.
struct AdoptSheet: View {
    @Environment(\.dismiss) private var dismiss
    var target: AdoptTarget
    var state: InstallationModel

    @State private var repository = ""
    @State private var isAdopting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adopt \(target.folder)").font(.title3.weight(.semibold))

            Form {
                LabeledContent("Folder", value: target.folder)
                LabeledContent("Title", value: target.toc?.title ?? "—")
                LabeledContent("Version", value: target.toc?.version ?? "—")
                TextField("GitHub repository", text: $repository, prompt: Text("owner/repo"))
                    .onSubmit(adopt)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Text("ForeverAddons will install the latest Forever release of this repository over the existing folder, then keep it up to date.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = state.row("unmanaged:\(target.folder)").error {
                RowErrorText(message: error)
            }

            HStack {
                if isAdopting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Adopt", action: adopt)
                    .keyboardShortcut(.defaultAction)
                    .disabled(Self.parse(repository) == nil || isAdopting)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { repository = target.suggestedRef?.identifier ?? "" }
    }

    private func adopt() {
        guard let ref = Self.parse(repository), !isAdopting else { return }
        isAdopting = true
        Task {
            let succeeded = await state.adopt(folder: target.folder, as: ref)
            isAdopting = false
            if succeeded { dismiss() }
        }
    }

    /// Accepts `owner/repo` or a `github.com/owner/repo` URL.
    static func parse(_ text: String) -> AddonRef? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "github.com/"] where trimmed.lowercased().hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count))
        }
        if trimmed.hasSuffix(".git") { trimmed = String(trimmed.dropLast(4)) }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts.allSatisfy({ !$0.contains(" ") }) else { return nil }
        return AddonRef(source: .github, identifier: "\(parts[0])/\(parts[1])")
    }
}
