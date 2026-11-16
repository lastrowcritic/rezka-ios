#if os(iOS)
import Foundation
import XCTest
@testable import RezkaPort

private final class SyncFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [(Int, Data)] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func prepare(_ json: [(Int, String)]) {
        lock.withLock {
            replies = json.map { ($0.0, Data($0.1.utf8)) }
            requests = []
        }
    }
    static var captured: [URLRequest] { lock.withLock { requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // URLSession may turn httpBody into a stream before URLProtocol sees it.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        let reply: (Int, Data)? = Self.lock.withLock {
            Self.requests.append(captured)
            return Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ServerWatchSyncClientTests: XCTestCase {
    private final class MemoryCredentials: ServerSyncCredentialStore {
        var saved: ServerSyncCredentials?
        func read() -> ServerSyncCredentials? { saved }
        func write(token: String, email: String, expiresAt: Double, server: String) throws {
            saved = ServerSyncCredentials(token: token, email: email, expiresAt: expiresAt, server: server)
        }
        func delete() { saved = nil }
    }
    private let auth = "{\"token\":\"test-token\",\"expiresAt\":9999999999999,\"user\":{\"id\":\"1\",\"email\":\"test@example.com\"}}"

    private func client() throws -> ServerWatchSyncClient {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ServerSyncTests-\(UUID().uuidString)"))
        defaults.set("https://sync.example.com/rezka", forKey: "syncServer")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncFixtureProtocol.self]
        return ServerWatchSyncClient(defaults: defaults, session: URLSession(configuration: config), credentials: MemoryCredentials())
    }

    func testServerProtocolPreservesSubpathBearerAndMilliseconds() async throws {
        SyncFixtureProtocol.prepare([(200, auth), (200, "{\"records\":[],\"clearedAt\":0}"), (200, "{\"records\":[],\"clearedAt\":0}")])
        let client = try client()
        try await client.authenticate(mode: "login", email: "test@example.com", password: "test-password")
        let item = MediaItem(id: "film", title: "Film", kind: .movie, genre: "", synopsis: "", symbol: "film", paletteIndex: 0)
        let record = WatchRecord(item: item, position: 123, duration: 1000, updatedAt: Date(timeIntervalSince1970: 100))
        let result = try await client.exchange(WatchHistorySnapshot(records: [record]))
        let requests = SyncFixtureProtocol.captured
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "PUT"])
        XCTAssertEqual(requests.last?.url?.path, "/rezka/v1/history")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let body = try XCTUnwrap(requests.last?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [[String: Any]]])
        XCTAssertEqual(object["records"]?.first?["updatedAt"] as? Double, 100_000)
        XCTAssertEqual(result.records.first?.position, 123)
    }

    func testOfflineClearIsAcknowledgedAndRetainsLaterLocalPlayback() async throws {
        SyncFixtureProtocol.prepare([(200, auth), (200, "{\"records\":[],\"clearedAt\":0}"),
                                     (200, "{\"records\":[],\"clearedAt\":300000}"), (200, "{\"records\":[],\"clearedAt\":300000}")])
        let client = try client()
        try await client.authenticate(mode: "login", email: "test@example.com", password: "test-password")
        let item = MediaItem(id: "film", title: "Film", kind: .movie, genre: "", synopsis: "", symbol: "film", paletteIndex: 0)
        let record = WatchRecord(item: item, position: 123, duration: 1000, updatedAt: Date(timeIntervalSince1970: 200))
        var second = record
        second.item.id = "second"
        second.updatedAt = Date(timeIntervalSince1970: 210)
        let result = try await client.exchange(WatchHistorySnapshot(records: [record, second], clearedAt: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(SyncFixtureProtocol.captured.map(\.httpMethod), ["POST", "GET", "DELETE", "PUT"])
        XCTAssertEqual(result.records.map(\.item.id), ["second", "film"])
        XCTAssertEqual(result.records.last?.position, 123)
        XCTAssertGreaterThan(try XCTUnwrap(result.records.last?.updatedAt), result.clearedAt)
        XCTAssertLessThan(try XCTUnwrap(result.records.first?.updatedAt).timeIntervalSince(result.clearedAt), 0.003)
    }

    func testExpiredSessionExposesSignInAgain() async throws {
        SyncFixtureProtocol.prepare([(200, auth), (401, "{\"error\":\"Session expired. Sign in again.\"}")])
        let client = try client()
        try await client.authenticate(mode: "login", email: "test@example.com", password: "test-password")
        do {
            _ = try await client.exchange(.init())
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Sign in again"))
            XCTAssertNil(client.email)
        }
    }
}
#endif
