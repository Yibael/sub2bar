import XCTest
import Sub2BarCore
@testable import Sub2Bar

@MainActor
final class CredentialSessionTests: XCTestCase {
    private let server = "https://example.invalid"
    private func waitForRead(_ vault: MemoryVault) async {
        for _ in 0..<2000 {
            if await vault.counts().reads > 0 { return }
            await Task.yield()
        }
        XCTFail("Expected file read")
    }
    func testCacheUsesOneFileReadForRepeatedLoads() async throws {
        let vault = MemoryVault(); let session = CredentialSession(storage: vault)
        for _ in 0..<10 { _ = try await session.load(for: server) }
        XCTAssertEqual(session.cachedKey(for: server), "fake-secret")
        let counts = await vault.counts(); XCTAssertEqual(counts.reads, 1)
    }
    func testConcurrentLoadsShareOneRead() async throws {
        let vault = MemoryVault(); await vault.hold()
        let session = CredentialSession(storage: vault)
        let first = Task { try await session.load(for: server) }
        await waitForRead(vault)
        let second = Task { try await session.load(for: server) }
        for _ in 0..<10 { await Task.yield() }
        await vault.complete("fake-secret")
        _ = try await first.value; _ = try await second.value
        let counts = await vault.counts(); XCTAssertEqual(counts.reads, 1)
    }
    func testSaveAndUnchangedSaveWriteOnceWithoutReading() async throws {
        let vault = MemoryVault(); let session = CredentialSession(storage: vault)
        try await session.save(" fake-secret ", for: server)
        try await session.save("fake-secret", for: server)
        let counts = await vault.counts(); XCTAssertEqual(counts.reads, 0); XCTAssertEqual(counts.writes, 1)
    }
    func testServerIsolationAndStaleReadCannotOverwriteSavedKey() async throws {
        let vault = MemoryVault(); await vault.hold()
        let session = CredentialSession(storage: vault)
        let first = Task { try await session.load(for: server) }
        await waitForRead(vault)
        try await session.save("new", for: "https://other.invalid")
        await vault.complete("old")
        do { _ = try await first.value; XCTFail("Expected invalidated load") } catch { }
        XCTAssertNil(session.cachedKey(for: server))
        XCTAssertEqual(session.cachedKey(for: "https://other.invalid"), "new")
    }
    func testCallerCancellationKeepsSuccessfulLocalRead() async throws {
        let vault = MemoryVault(); await vault.hold()
        let session = CredentialSession(storage: vault)
        let first = Task { try await session.load(for: server) }
        await waitForRead(vault); first.cancel(); await vault.complete("fake-secret")
        _ = try? await first.value
        XCTAssertEqual(session.cachedKey(for: server), "fake-secret")
    }
    func testEmptyOrMultilineKeyRejectedAndClearDropsCache() async throws {
        let vault = MemoryVault(); let session = CredentialSession(storage: vault)
        for key in ["", " ", "a\nb", "a\rb"] {
            do { try await session.save(key, for: server); XCTFail("Expected invalid key") }
            catch { XCTAssertEqual(error as? APIError, .missingKey) }
        }
        try await session.save("valid", for: server); session.clear()
        XCTAssertNil(session.cachedKey(for: server))
    }
}

final class LocalCredentialStorageTests: XCTestCase {
    private func temporary() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sub2bar-storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return path
    }
    func testRoundTripOwnerOnlyPermissionsAndNoEncryptionClaim() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let storage = LocalCredentialStorage(directory: dir.appendingPathComponent("app"))
        try await storage.write("fake-secret", for: "https://example.invalid")
        let key = try await storage.read(for: "https://example.invalid")
        XCTAssertEqual(key, "fake-secret")
        let app = dir.appendingPathComponent("app")
        let file = app.appendingPathComponent("credential.json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: app.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertTrue(try String(contentsOf: file).contains("fake-secret"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: app.path), ["credential.json"])
    }
    func testMissingStorageDoesNotCreateFiles() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let child = dir.appendingPathComponent("absent")
        let value = try await LocalCredentialStorage(directory: child).read(for: "https://example.invalid")
        XCTAssertEqual(value, ""); XCTAssertFalse(FileManager.default.fileExists(atPath: child.path))
    }
    func testNewProcessReadsSavedKeyAndOtherServerCannotReadIt() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        try await LocalCredentialStorage(directory: dir).write("fake-secret", for: "https://example.invalid")
        let restarted = LocalCredentialStorage(directory: dir)
        let other = try await restarted.read(for: "https://other.invalid")
        let current = try await restarted.read(for: "https://example.invalid")
        XCTAssertEqual(other, ""); XCTAssertEqual(current, "fake-secret")
    }
    func testAtomicReplacementKeepsPermissions() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let storage = LocalCredentialStorage(directory: dir)
        try await storage.write("first", for: "A"); try await storage.write("second", for: "B")
        let value = try await storage.read(for: "B"); XCTAssertEqual(value, "second")
        let old = try await storage.read(for: "A"); XCTAssertEqual(old, "")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("credential.json").path)[.posixPermissions] as? Int, 0o600)
    }
    func testRejectsReadableByOtherUsers() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let storage = LocalCredentialStorage(directory: dir)
        try await storage.write("fake", for: "A")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("credential.json").path)
        do { _ = try await storage.read(for: "A"); XCTFail("Unsafe permission must be rejected") }
        catch { XCTAssertTrue(error is LocalCredentialError) }
    }
    func testRejectsSymlinkFileAndDirectory() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let actual = dir.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        do { _ = try await LocalCredentialStorage(directory: alias).read(for: "A"); XCTFail("Directory symlink") } catch { }
        let outside = dir.appendingPathComponent("outside")
        try Data("not-a-secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: actual.appendingPathComponent("credential.json"), withDestinationURL: outside)
        do { _ = try await LocalCredentialStorage(directory: actual).read(for: "A"); XCTFail("File symlink") } catch { }
        XCTAssertEqual(try String(contentsOf: outside), "not-a-secret")
    }
    func testCorruptFileFailsWithoutReturningContents() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let storage = LocalCredentialStorage(directory: dir)
        try await storage.write("fake", for: "A")
        let file = dir.appendingPathComponent("credential.json")
        try Data("private-invalid-payload".utf8).write(to: file)
        do { _ = try await storage.read(for: "A"); XCTFail("Expected decode error") }
        catch { XCTAssertFalse(error.localizedDescription.contains("private-invalid-payload")) }
    }
}
