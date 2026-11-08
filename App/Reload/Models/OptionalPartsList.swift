import AddonKit
import Foundation
import Observation

/// One managed add-on's optional parts, as rows. Empty until the core reports some, and then
/// the inspector shows the section.
@Observable @MainActor
final class OptionalPartsList {
    let ref: AddonRef
    private(set) var rows: [OptionalPartRow] = []
    /// The last listing failed; the rows already shown stay.
    private(set) var error: String?

    init(ref: AddonRef) {
        self.ref = ref
    }

    func apply(_ parts: [OptionalPart]) {
        let rows = parts.map(OptionalPartRow.init)
        if rows != self.rows { self.rows = rows }
        if error != nil { error = nil }
    }

    func fail(_ message: String) {
        if error != message { error = message }
    }
}
