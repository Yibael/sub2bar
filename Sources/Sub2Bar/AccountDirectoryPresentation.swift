import Foundation
import Sub2BarCore

/// Local presentation only: filtering must not load accounts or change Pin order.
struct AccountDirectoryPresentation {
    let pinned: [Account]
    let others: [Account]
    let missingPinnedIDs: [Int]

    init(accounts: [Account], pinnedIDs: [Int], hasLoaded: Bool,
         search: String = "", onlyPinned: Bool = false, onlyOAuth: Bool = false) {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let positions = Dictionary(uniqueKeysWithValues: pinnedIDs.enumerated().map { ($0.element, $0.offset) })
        let matches = accounts.filter { account in
            (!onlyOAuth || account.supportsSubscription) &&
            (query.isEmpty || account.name.localizedCaseInsensitiveContains(query) ||
             account.platformLabel.localizedCaseInsensitiveContains(query) || String(account.id).contains(query))
        }
        pinned = matches.filter { positions[$0.id] != nil }
            .sorted { positions[$0.id]! < positions[$1.id]! }
        others = onlyPinned ? [] : matches.filter { positions[$0.id] == nil }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        // Keep missing Pins recoverable even with filters active; their type
        // and name cannot be determined from an incomplete directory entry.
        let known = Set(accounts.map(\.id))
        missingPinnedIDs = hasLoaded ? pinnedIDs.filter { !known.contains($0) } : []
    }

    var isEmpty: Bool { pinned.isEmpty && others.isEmpty && missingPinnedIDs.isEmpty }
}
