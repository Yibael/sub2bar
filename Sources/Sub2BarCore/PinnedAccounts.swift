import Foundation

/// Only IDs are persisted. Different server URLs may reuse the same account ID.
public struct PinnedAccountSelection: Codable, Sendable {
    private var servers: [String: [Int]] = [:]
    public init() { }

    public func ids(for server: String) -> [Int] {
        var seen = Set<Int>()
        return (servers[server] ?? []).filter { $0 > 0 && seen.insert($0).inserted }
    }

    public mutating func setPinned(_ pinned: Bool, id: Int, server: String) {
        guard id > 0 else { return }
        var ids = ids(for: server)
        if pinned {
            if !ids.contains(id) { ids.append(id) }
        } else { ids.removeAll { $0 == id } }
        servers[server] = ids
    }
}

public struct PinnedSnapshotResult: Sendable {
    public let snapshots: [AccountSnapshot]
    public let accountErrors: [Int: String]
    public init(snapshots: [AccountSnapshot], accountErrors: [Int: String]) {
        self.snapshots = snapshots
        self.accountErrors = accountErrors
    }
}
