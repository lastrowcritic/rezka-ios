import Foundation

/// The watched library, including completed movies and individual episode positions.
/// A durable clear marker prevents an offline device from restoring deleted history.
struct WatchHistorySnapshot: Codable, Sendable {
    var records: [WatchRecord] = []
    var clearedAt: Date = Date(timeIntervalSince1970: 0)

    func merging(_ other: Self) -> Self {
        let cutoff = max(clearedAt, other.clearedAt)
        var latest: [String: WatchRecord] = [:]
        for record in other.records + records where record.updatedAt > cutoff {
            guard record.position.isFinite, record.position >= 0, record.duration.isFinite else { continue }
            if latest[record.syncKey].map({ $0.updatedAt >= record.updatedAt }) != true {
                latest[record.syncKey] = record
            }
        }
        return Self(records: Array(latest.values.sorted(by: Self.mostRecentFirst).prefix(500)), clearedAt: cutoff)
    }

    var latestByTitle: [WatchRecord] {
        var seen = Set<String>()
        return merging(Self()).records.filter { seen.insert($0.item.id).inserted }
    }

    static func mostRecentFirst(_ lhs: WatchRecord, _ rhs: WatchRecord) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.syncKey < rhs.syncKey : lhs.updatedAt > rhs.updatedAt
    }
}

extension WatchRecord {
    /// An encoded tuple avoids collisions between media and episode identifiers.
    var syncKey: String {
        let data = try! JSONEncoder().encode([item.id, seasonID, episodeID])
        return String(decoding: data, as: UTF8.self)
    }
}

enum WatchSyncMode: String, CaseIterable, Identifiable {
    case off, appleCloud, server
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .appleCloud: "Apple Cloud (iCloud)"
        case .server: "Custom server URL"
        }
    }
}
