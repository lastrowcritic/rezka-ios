#if DEBUG
import Foundation

/// Offline UI acceptance transport: a second device starts a series, then returns
/// to its movie. Production builds and normal launches never use this backend.
@MainActor
final class RezkaUITestWatchSyncBackend: WatchHistorySyncBackend {
    private var calls = 0
    private let timestamp = Date.now

    func exchange(_ local: WatchHistorySnapshot) async throws -> WatchHistorySnapshot {
        calls += 1
        let movie = MediaItem(id: "sync-movie", title: "Synced movie", kind: .movie,
                              genre: "Drama", synopsis: "", symbol: "film", paletteIndex: 0)
        let series = MediaItem(id: "sync-series", title: "Synced series", kind: .series,
                               genre: "Drama", synopsis: "", symbol: "tv", paletteIndex: 1)
        var remote = [WatchRecord(item: movie, position: calls >= 3 ? 240 : 120, duration: 1200,
                                  updatedAt: timestamp.addingTimeInterval(calls >= 3 ? 2 : 0))]
        if calls >= 2 {
            remote.append(WatchRecord(item: series, position: 330, duration: 1800,
                                      updatedAt: timestamp.addingTimeInterval(1), seasonID: "2", episodeID: "3"))
        }
        return local.merging(WatchHistorySnapshot(records: remote))
    }
}
#endif
