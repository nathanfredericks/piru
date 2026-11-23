import SwiftUI

extension Array {
    /// Removes elements at offsets that are still valid for the current array.
    mutating func remove(inRangeOffsets offsets: IndexSet) {
        let valid = IndexSet(offsets.filter { indices.contains($0) })
        guard !valid.isEmpty else { return }
        remove(atOffsets: valid)
    }
}
