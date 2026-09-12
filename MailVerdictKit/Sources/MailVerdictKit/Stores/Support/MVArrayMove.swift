import Foundation

extension Array {
    /// `Array.move(fromOffsets:toOffset:)`'s own shape — `List.onMove` hands a screen exactly
    /// this pair — but that method itself lives in SwiftUI, not the standard library, so a
    /// package store a Linux test drives directly needs its own copy. `destination` is an index
    /// into the array as it stood *before* removal; the subtraction below is what keeps the
    /// insertion point correct once the moved elements are gone from ahead of it.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[$0] }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        for offset in source.sorted(by: >) {
            remove(at: offset)
        }
        insert(contentsOf: moving, at: Swift.max(0, Swift.min(adjustedDestination, count)))
    }
}
