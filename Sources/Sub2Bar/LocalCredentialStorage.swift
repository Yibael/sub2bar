import Foundation
import Darwin

enum LocalCredentialError: Error, LocalizedError {
    case unavailable, unsafeFile, invalidData
    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法读写本地密钥文件，请检查应用支持目录的权限。"
        case .unsafeFile: return "本地密钥文件的类型或权限不安全，已停止读取。"
        case .invalidData: return "本地密钥文件无法解析，请在设置中重新输入 Admin Key 并保存。"
        }
    }
}

/// Plaintext, owner-only local storage. No Keychain, embedded encryption key,
/// credential export, or hidden migration from previous versions.
actor LocalCredentialStorage: CredentialStorage {
    struct Entry: Codable { let server: String; let key: String }
    private let directory: URL
    private let filename = "credential.json"

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.sub2bar.app", isDirectory: true)
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        if create {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch { throw LocalCredentialError.unavailable }
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if !create && errno == ENOENT { return nil }
            throw LocalCredentialError.unsafeFile
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & 0o777) == 0o700 else {
            close(fd)
            throw LocalCredentialError.unsafeFile
        }
        return fd
    }

    func read(for server: String) async throws -> String {
        guard let dir = try openDirectory(create: false) else { return "" }
        defer { close(dir) }
        let fd = openat(dir, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return "" }
            throw LocalCredentialError.unsafeFile
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, (info.st_mode & 0o777) == 0o600,
              info.st_size > 0, info.st_size <= 65536 else { throw LocalCredentialError.unsafeFile }
        let data: Data
        do { data = try handle.readToEnd() ?? Data() }
        catch { throw LocalCredentialError.unavailable }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else { throw LocalCredentialError.invalidData }
        return entry.server == server ? entry.key : ""
    }

    func write(_ key: String, for server: String) async throws {
        guard key.utf8.count < 16384, server.utf8.count < 8192 else { throw LocalCredentialError.invalidData }
        guard let dir = try openDirectory(create: true) else { throw LocalCredentialError.unavailable }
        defer { close(dir) }
        let data = try JSONEncoder().encode(Entry(server: server, key: key))
        let temporary = ".credential-\(UUID().uuidString)"
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalCredentialError.unavailable }
        defer { unlinkat(dir, temporary, 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            guard fchmod(fd, 0o600) == 0 else { throw LocalCredentialError.unavailable }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard renameat(dir, temporary, dir, filename) == 0 else { throw LocalCredentialError.unavailable }
        } catch { try? handle.close(); throw LocalCredentialError.unavailable }
    }
}
