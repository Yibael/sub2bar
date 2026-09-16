import Foundation
import Sub2BarCore

protocol CredentialStorage: Sendable {
    func read(for server: String) async throws -> String
    func write(_ key: String, for server: String) async throws
}

enum CredentialSessionError: Error, LocalizedError {
    case notLoaded
    case busy
    var errorDescription: String? {
        switch self {
        case .notLoaded: return "请在设置中输入 Admin Key 并保存。"
        case .busy: return "正在保存设置，请稍候。"
        }
    }
}

/// One server-scoped credential in process memory. Storage is read once on load;
/// network refreshes only use this cache.
@MainActor
final class CredentialSession {
    private struct Entry {
        let server: String
        let key: String
    }
    private struct Pending {
        let id: UUID
        let server: String
        let task: Task<String, Error>
    }
    private let storage: any CredentialStorage
    private var entry: Entry?
    private var pending: Pending?
    private var generation = UUID()

    init(storage: any CredentialStorage = LocalCredentialStorage()) { self.storage = storage }

    func cachedKey(for server: String) -> String? {
        guard entry?.server == server else { return nil }
        return entry?.key
    }

    func requireCachedKey(for server: String) throws -> String {
        guard let key = cachedKey(for: server) else { throw CredentialSessionError.notLoaded }
        return key
    }

    /// Share file reads across startup, panel and Settings. No authorization UI.
    func load(for server: String) async throws -> String {
        if let key = cachedKey(for: server) { return key }
        if let pending, pending.server == server { return try await pending.task.value }
        clear()
        let token = generation
        let id = UUID()
        let storage = storage
        let task = Task { [weak self] in
            do {
                let raw = try await storage.read(for: server)
                let key = try Self.validated(raw)
                guard let self, self.generation == token, !Task.isCancelled else { throw CancellationError() }
                self.entry = Entry(server: server, key: key)
                if self.pending?.id == id { self.pending = nil }
                return key
            } catch {
                if let self, self.pending?.id == id { self.pending = nil }
                throw error
            }
        }
        pending = Pending(id: id, server: server, task: task)
        return try await task.value
    }

    func save(_ raw: String, for server: String) async throws {
        let key = try Self.validated(raw)
        // Changing only the refresh interval must not rewrite the local secret.
        if cachedKey(for: server) == key { return }
        clear()
        let token = generation
        try await storage.write(key, for: server)
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        entry = Entry(server: server, key: key)
    }

    func clear() {
        generation = UUID()
        entry = nil
        pending?.task.cancel()
        pending = nil
    }

    private static func validated(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw APIError.missingKey }
        return key
    }
}
