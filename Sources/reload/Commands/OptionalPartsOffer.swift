import AddonKit
import Foundation

/// What `install --with-optional` and `info` say about optional parts
/// (docs/features/optional-parts.md). The core finds them; this only words and asks.
enum OptionalPartsOffer {
    /// The parts of every installed add-on in `refs`, one per folder. Revalidated as an
    /// explicit look at those add-ons; a failed lookup counts as none.
    static func gather(_ refs: [AddonRef], context: CLIContext, installation: Installation) async -> [OptionalPart] {
        var parts: [OptionalPart] = []
        for ref in refs {
            for part in (try? await context.manager.optionalParts(of: ref, in: installation, policy: .revalidateIfStale)) ?? []
            where !parts.contains(where: { $0.id == part.id }) {
                parts.append(part)
            }
        }
        return parts
    }

    /// After an install with `--with-optional`: asks about each available part (`[y/N]`, as
    /// they can be over 1 GB; `--yes` accepts all) and installs the accepted ones. Unmanaged
    /// ones get the `adopt` command. Without a terminal or `--yes`, only lists them. Returns
    /// the parts as they stand afterwards and how many installs were tried.
    static func run(
        after outcome: inout BatchInstaller.Outcome, force: Bool, context: CLIContext, installation: Installation
    ) async throws -> (parts: [OptionalPart], attempted: Int) {
        let owners = outcome.installed.map(\.id)
        let parts = await gather(owners, context: context, installation: installation)
        let offers = context.yes || context.interactive
        var accepted: [BatchInstaller.Request] = []
        for part in parts {
            switch part.state {
            case .installed:
                continue
            case .unmanaged:
                context.note("\(part.folder) is in AddOns but not managed; `reload adopt \(part.folder) \(Format.ref(part.ref))` keeps it updated.")
            case .available:
                guard offers else {
                    context.note("\(describe(part)) is available: `reload install \(Format.ref(part.ref))`.")
                    continue
                }
                if try context.confirm("\(describe(part)) is optional. Install it?", action: "install") {
                    accepted.append(BatchInstaller.Request(ref: part.ref, channel: .stable, version: nil, pin: false))
                }
            }
        }
        guard !accepted.isEmpty else { return (parts, 0) }
        let more = await BatchInstaller.run(accepted, force: force, context: context, installation: installation)
        outcome.installed += more.installed
        outcome.failures += more.failures
        return (await gather(owners, context: context, installation: installation), accepted.count)
    }

    // MARK: - Wording

    /// "VoicesPlacesAudio (places-audio/v2.1.0, 456 MB, for Voices_Places)".
    static func describe(_ part: OptionalPart) -> String {
        var details = [part.version]
        if let size = part.downloadSize { details.append(Format.bytes(size)) }
        if !part.usedBy.isEmpty { details.append("for " + DependencyOffer.list(part.usedBy)) }
        return "\(part.folder) (\(details.joined(separator: ", ")))"
    }

    static func stateName(_ state: OptionalPart.State) -> String {
        switch state {
        case .available: "available"
        case .unmanaged: "not managed"
        case .installed: "installed"
        }
    }
}

/// An `OptionalPart` in `--json` output.
struct OptionalPartJSON: Encodable, Equatable {
    var ref: AddonRef
    var folder: String
    var usedBy: [String]
    var version: String
    var downloadSize: Int64?
    /// `available`, `unmanaged` or `installed`.
    var state: String

    init(_ part: OptionalPart) {
        ref = part.ref
        folder = part.folder
        usedBy = part.usedBy
        version = part.version
        downloadSize = part.downloadSize
        state = switch part.state {
        case .available: "available"
        case .unmanaged: "unmanaged"
        case .installed: "installed"
        }
    }
}
