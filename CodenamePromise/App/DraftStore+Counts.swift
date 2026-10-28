import CodenamePromiseCore
import Foundation
import SwiftData

extension DraftStore {
    /// How many entries are in Recently Deleted, counted by the store rather than by loading
    /// every one of them to count the array. Here rather than in Core because only Settings
    /// asks, for the number on its tile.
    func trashedCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<EntryDraft>(predicate: #Predicate { $0.deletedAt != nil }))
    }
}
