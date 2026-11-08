import Foundation

/// An optional add-on that a managed add-on can use, published as its own release stream in
/// the same GitHub repo (docs/features/optional-parts.md). Spoken's voice packs are the
/// example: `Spoken_Places.toc` lists `## OptionalDeps: SpokenPlacesAudio`, and the repo
/// publishes `SpokenPlacesAudio-2.1.0.zip` under `places-audio/v2.1.0`.
public struct OptionalPart: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        /// Not in `AddOns/`.
        case available
        /// In `AddOns/` but not managed; adopting it as `ref` makes Reload update it.
        case unmanaged
        /// Managed by Reload as `ref`.
        case installed
    }

    /// The repo plus the part's `tagPrefix`; install, update and adopt it like any other ref.
    public var ref: AddonRef
    /// The folder the TOC names, e.g. `SpokenPlacesAudio`.
    public var folder: String
    /// Folders of the managed add-on whose loaded TOC lists it, e.g. `Spoken_Places`.
    public var usedBy: [String]
    /// Latest stable tag in the part's stream, e.g. `places-audio/v2.1.0`.
    public var version: String
    /// Size of the zip that would be downloaded, when known.
    public var downloadSize: Int64?
    public var state: State

    public var id: String { folder.lowercased() }

    public init(ref: AddonRef, folder: String, usedBy: [String], version: String, downloadSize: Int64?, state: State) {
        self.ref = ref
        self.folder = folder
        self.usedBy = usedBy
        self.version = version
        self.downloadSize = downloadSize
        self.state = state
    }
}
