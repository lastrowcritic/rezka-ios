import Foundation
import Observation
import Security

private struct SyncAccount: Decodable {
    let id: String
    let email: String
}

private struct SyncAuthResponse: Decodable {
    let token: String
    let expiresAt: Double
    let user: SyncAccount
}

private struct SyncHistoryResponse: Decodable {
    let records: [WatchRecord]
    let clearedAt: Double

    private enum CodingKeys: String, CodingKey { case records, clearedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One record this version cannot read must not stop the rest from syncing.
        records = try container.decode(LossyArray<WatchRecord>.self, forKey: .records).elements
        clearedAt = try container.decode(Double.self, forKey: .clearedAt)
    }
}

/// Syncs viewing history through a server the user hosts. Sync stays off until its address is set in Settings.
@MainActor
@Observable
final class ServerWatchSyncClient {
    private let defaults: UserDefaults
    private let session: URLSession
    private let credentials: any ServerSyncCredentialStore
    private static let serverKey = "syncServer"
    private(set) var server: URL?
    private var token: String?
    private(set) var email: String?
    private(set) var status = ""
    private(set) var lastError: String?

    init(defaults: UserDefaults = .standard, session: URLSession = .shared, credentials: any ServerSyncCredentialStore = KeychainServerSyncCredentialStore()) {
        self.defaults = defaults
        self.session = session
        self.credentials = credentials
        server = defaults.string(forKey: Self.serverKey).flatMap { try? SyncServerAddress.normalized($0) }
        // A session is only used with the server that issued it.
        if let server, let saved = credentials.read(), saved.server == server.absoluteString, saved.expiresAt > Date().timeIntervalSince1970 * 1000 {
            token = saved.token
            email = saved.email
        }
        status = server == nil ? "" : "Sign in to sync viewing history across devices."
    }

    /// Switches to another server. The session for the previous server is signed out first.
    func setServer(_ text: String) async throws {
        let next = try SyncServerAddress.normalized(text)
        guard next != server else { return }
        if token != nil { await signOut() }
        server = next
        defaults.set(next?.absoluteString, forKey: Self.serverKey)
        lastError = nil
        status = next == nil ? "" : "Sign in to sync viewing history across devices."
    }

    func authenticate(mode: String, email: String, password: String) async throws {
        status = "Signing in"
        lastError = nil
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let response: SyncAuthResponse = try await request("/v1/auth/\(mode)", method: "POST", body: body, as: SyncAuthResponse.self)
        try credentials.write(token: response.token, email: response.user.email, expiresAt: response.expiresAt, server: server?.absoluteString ?? "")
        token = response.token
        self.email = response.user.email
        status = "Signed in. Syncing viewing history."
    }

    func exchange(_ local: WatchHistorySnapshot) async throws -> WatchHistorySnapshot {
        guard let token else {
            throw NSError(domain: "WatchSync", code: 401, userInfo: [NSLocalizedDescriptionKey: "Sign in to your sync server first."])
        }
        var remote = try await request("/v1/history", method: "GET", bearer: token, as: SyncHistoryResponse.self)
        var records = local.records
        if local.clearedAt.timeIntervalSince1970 * 1000 > remote.clearedAt {
            remote = try await request("/v1/history", method: "DELETE", bearer: token, as: SyncHistoryResponse.self)
            // This API assigns its own clear time. Preserve playback recorded locally
            // after an offline clear, maintaining its relative recency after that time.
            let cutoff = Date(timeIntervalSince1970: remote.clearedAt / 1000)
            let retained = records.filter { $0.updatedAt > local.clearedAt }
                .sorted { WatchHistorySnapshot.mostRecentFirst($1, $0) }
            records = retained.enumerated().map { index, progress in
                var record = progress
                // Preserve order without shifting days of offline playback into
                // the future, where it could suppress later updates elsewhere.
                record.updatedAt = max(record.updatedAt, cutoff.addingTimeInterval(Double(index + 1) / 1000))
                return record
            }
        }
        let snapshot = WatchHistorySnapshot(records: remote.records, clearedAt: Date(timeIntervalSince1970: remote.clearedAt / 1000))
        let merged = snapshot.merging(WatchHistorySnapshot(records: records, clearedAt: local.clearedAt))
        let saved = try await push(merged.records)
        return merged.merging(WatchHistorySnapshot(records: saved.records, clearedAt: Date(timeIntervalSince1970: saved.clearedAt / 1000)))
    }

    func signOut() async {
        if let token {
            do { _ = try await request("/v1/auth/logout", method: "POST", bearer: token, as: EmptyResponse.self) }
            catch { }
        }
        self.token = nil
        email = nil
        credentials.delete()
        status = "Viewing history remains saved on this iPhone."
        lastError = nil
    }

    private func push(_ records: [WatchRecord]) async throws -> SyncHistoryResponse {
        guard let token else { throw URLError(.userAuthenticationRequired) }
        if records.isEmpty {
            return try await request("/v1/history", method: "GET", bearer: token, as: SyncHistoryResponse.self)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let body = try encoder.encode(["records": records])
        return try await request("/v1/history", method: "PUT", body: body, bearer: token, as: SyncHistoryResponse.self)
    }

    private func request<T: Decodable>(_ path: String, method: String, body: Data? = nil, bearer: String? = nil, as type: T.Type) async throws -> T {
        try Task.checkCancellation()
        guard let server else { throw URLError(.badURL) }
        var request = URLRequest(url: server.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 18
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw NSError(domain: "WatchSync", code: -3, userInfo: [NSLocalizedDescriptionKey: "The sync server could not be reached."]) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401, bearer != nil {
                token = nil
                email = nil
                credentials.delete()
            }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw NSError(domain: "WatchSync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message ?? "The sync server is temporarily unavailable."])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }

}

struct ServerSyncCredentials: Codable {
    let token: String
    let email: String
    let expiresAt: Double
    /// Missing in sessions saved before the server became configurable.
    let server: String?
}

@MainActor
protocol ServerSyncCredentialStore {
    func read() -> ServerSyncCredentials?
    func write(token: String, email: String, expiresAt: Double, server: String) throws
    func delete()
}

@MainActor
final class KeychainServerSyncCredentialStore: ServerSyncCredentialStore {
    func read() -> ServerSyncCredentials? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ServerSyncCredentials.self, from: data)
    }

    func write(token: String, email: String, expiresAt: Double, server: String) throws {
        let data = try JSONEncoder().encode(ServerSyncCredentials(token: token, email: email, expiresAt: expiresAt, server: server))
        delete()
        var query = keychainQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw NSError(domain: "WatchSync", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sign-in could not be saved securely."])
        }
    }

    func delete() {
        SecItemDelete(keychainQuery as CFDictionary)
    }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.personal.rezkaport.watch-sync", kSecAttrAccount as String: "session"]
    }
}

private struct EmptyResponse: Decodable {
    let ok: Bool?
}
