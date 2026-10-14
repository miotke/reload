import Foundation

/// Whether a source's add-ons appear in search and Browse (docs/features/sources.md).
/// Turning a source off never touches what's installed from it: those add-ons stay listed
/// and keep getting update checks.
public struct SourceSetting: Sendable, Hashable, Identifiable {
    public var source: SourceID
    public var isEnabled: Bool

    public var id: SourceID { source }

    public init(source: SourceID, isEnabled: Bool) {
        self.source = source
        self.isEnabled = isEnabled
    }
}

/// Stored in the metadata database so the app and `reload` share it. A source with no row
/// is on.
extension MetadataDatabase {
    func enabledSources() -> Set<SourceID> {
        let off = (try? query("SELECT source FROM source_settings WHERE enabled = 0"))?.compactMap { $0.string(0) } ?? []
        return Set(SourceID.allCases).subtracting(off.compactMap(SourceID.init(rawValue:)))
    }

    func setSource(_ source: SourceID, enabled: Bool) throws {
        let changed = try execute("""
            INSERT INTO source_settings(source, enabled) VALUES (?, ?)
            ON CONFLICT(source) DO UPDATE SET enabled = excluded.enabled WHERE source_settings.enabled IS NOT excluded.enabled
            """, source.rawValue, enabled)
        // Search and Browse read the catalogue through the enabled sources, so to them it changed.
        if changed > 0 { notify(["catalogue", "source_settings"]) }
    }
}
