import XCTest
@testable import Sub2BarCore

private final class BatchUsageProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class BatchUsageTests: XCTestCase {
    override func tearDown() { BatchUsageProtocol.handler = nil; super.tearDown() }

    private func client() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BatchUsageProtocol.self]
        return APIClient(configuration: Configuration(serverURL: "https://example.invalid"),
                         key: "test-admin-key", session: URLSession(configuration: config))
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while data.count < 65_536 {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testBatchOnlyQueriesSelectedIDsAndNeverForcesUpstream() async throws {
        BatchUsageProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/admin/accounts/usage/batch")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-admin-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let payload = try self.body(request)
            XCTAssertEqual(payload["account_ids"] as? [Int], [7, 2])
            XCTAssertEqual(payload["force"] as? Bool, false)
            return (200, #"{"code":0,"data":{"usage":{"7":{"seven_day":{"utilization":50,"window_stats":{"cost":25}}},"2":{"seven_day":{"utilization":20}},"999":{"seven_day":{"utilization":90}}},"errors":{}}}"#)
        }
        let results = try await client().loadUsageBatch(ids: [7, 2, 7, 0, -1])
        XCTAssertEqual(results.map(\.id), [7, 2])
        XCTAssertEqual(results[0].usage?.sevenDay?.estimatedTotalCost, 50)
        XCTAssertTrue(results.allSatisfy { $0.error == nil })
    }

    func testMissingAndFailedBatchEntriesAreIsolatedAndSanitized() async throws {
        BatchUsageProtocol.handler = { _ in
            (200, #"{"code":0,"data":{"usage":{"1":{"seven_day":{"utilization":50}},"4":{"error":"private-secret-error"}},"errors":{"2":"private-secret-error"}}}"#)
        }
        let results = try await client().loadUsageBatch(ids: [1, 2, 3, 4])
        XCTAssertNotNil(results[0].usage)
        for result in results.dropFirst() {
            XCTAssertNil(result.usage)
            XCTAssertEqual(result.error, "额度读取失败")
        }
    }

    func testNoIDsMakesNoBatchRequest() async throws {
        BatchUsageProtocol.handler = { _ in XCTFail("No request expected"); return (500, "") }
        let results = try await client().loadUsageBatch(ids: [0, -1])
        XCTAssertTrue(results.isEmpty)
    }

    func testLargeBatchesAreBoundedAndDeduplicated() async throws {
        var sizes: [Int] = []
        BatchUsageProtocol.handler = { request in
            let payload = try self.body(request)
            let ids = try XCTUnwrap(payload["account_ids"] as? [Int])
            sizes.append(ids.count)
            XCTAssertEqual(payload["force"] as? Bool, false)
            let values = Dictionary(uniqueKeysWithValues: ids.map { (String($0), ["seven_day": ["utilization": 50]]) })
            let data = try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["usage": values, "errors": [:]]])
            return (200, String(decoding: data, as: UTF8.self))
        }
        let results = try await client().loadUsageBatch(ids: Array(1...205))
        XCTAssertEqual(sizes, [100, 100, 5])
        XCTAssertEqual(results.map(\.id), Array(1...205))
    }

    func testBatchAuthenticationErrorDoesNotExposeBody() async {
        BatchUsageProtocol.handler = { _ in (401, "private-secret-error") }
        do { _ = try await client().loadUsageBatch(ids: [1]); XCTFail("Expected auth error") }
        catch { XCTAssertEqual(error as? APIError, .http(401)) }
    }
}
