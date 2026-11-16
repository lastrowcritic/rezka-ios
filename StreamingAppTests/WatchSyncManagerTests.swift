#if os(iOS)
import XCTest
@testable import RezkaPort

@MainActor
final class WatchSyncManagerTests: XCTestCase {
    @MainActor
    private final class Backend: WatchHistorySyncBackend {
        var remote = WatchHistorySnapshot()
        var received: [WatchHistorySnapshot] = []
        var suspended: CheckedContinuation<Void, Never>?
        var pause = false
        var fail = false
        func exchange(_ local: WatchHistorySnapshot) async throws -> WatchHistorySnapshot {
            received.append(local)
            if pause { await withCheckedContinuation { suspended = $0 } }
            if fail { throw URLError(.notConnectedToInternet) }
            remote = remote.merging(local)
            return remote
        }
    }

    private func fixture() throws -> (UserDefaults, Backend, WatchSyncManager, AppModel) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RezkaSyncTests-\(UUID().uuidString)"))
        let backend = Backend()
        let sync = WatchSyncManager(defaults: defaults, appleBackend: backend)
        return (defaults, backend, sync, AppModel(defaults: defaults, watchSync: sync))
    }

    private func title(_ id: String, series: Bool = false) -> MediaItem {
        MediaItem(id: id, title: id, kind: series ? .series : .movie, genre: "Drama", synopsis: "", symbol: "film", paletteIndex: 0)
    }

    func testEnablingCloudImmediatelyImportsAnotherDevicesContinueWatchingAndPersistsIt() async throws {
        let (defaults, backend, sync, model) = try fixture()
        let series = title("tablet-series", series: true)
        backend.remote.records = [WatchRecord(item: series, position: 530, duration: 1800, updatedAt: .now, seasonID: "2", episodeID: "3")]
        await sync.selectMode(.appleCloud)
        XCTAssertEqual(model.continueWatching.map(\.item.id), [series.id])
        XCTAssertEqual(model.episodeRecord(mediaID: series.id, season: "2", episode: "3")?.position, 530)
        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.continueWatching.map(\.item.id), [series.id])
        XCTAssertEqual(restored.watchSync.mode, .appleCloud)
    }

    func testCompletedMovieSyncsAndDoesNotReappearAfterRelaunch() async throws {
        let (defaults, backend, sync, model) = try fixture()
        model.recordProgress(for: title("film"), position: 1000, duration: 1000)
        await sync.selectMode(.appleCloud)
        XCTAssertEqual(backend.remote.records.first?.progress, 1)
        XCTAssertTrue(model.continueWatching.isEmpty)
        XCTAssertTrue(AppModel(defaults: defaults).continueWatching.isEmpty)
    }

    func testLateResponseCannotRollBackPlaybackSavedDuringSync() async throws {
        let (_, backend, sync, model) = try fixture()
        await sync.selectMode(.appleCloud)
        model.recordProgress(for: title("film"), position: 100, duration: 1000)
        backend.pause = true
        let task = Task { await sync.syncNow() }
        while backend.suspended == nil { await Task.yield() }
        model.recordProgress(for: title("film"), position: 200, duration: 1000)
        backend.pause = false
        backend.suspended?.resume()
        await task.value
        XCTAssertEqual(model.continueWatching.first?.position, 200)
        XCTAssertEqual(backend.remote.records.first?.position, 200)
        await sync.selectMode(.off)
    }

    func testTurningSyncOffDiscardsInFlightResult() async throws {
        let (_, backend, sync, model) = try fixture()
        await sync.selectMode(.appleCloud)
        backend.remote.records = [WatchRecord(item: title("remote"), position: 100, duration: 1000, updatedAt: .now)]
        backend.pause = true
        let task = Task { await sync.syncNow() }
        while backend.suspended == nil { await Task.yield() }
        let disable = Task { await sync.selectMode(.off) }
        await Task.yield()
        backend.suspended?.resume()
        await disable.value
        await task.value
        XCTAssertEqual(sync.mode, .off)
        XCTAssertTrue(model.continueWatching.isEmpty)
    }

    func testOfflineClearSurvivesRelaunchAndIsRetriedWithoutResurrectingHistory() async throws {
        let (defaults, backend, sync, model) = try fixture()
        model.recordProgress(for: title("film"), position: 100, duration: 1000)
        await sync.selectMode(.appleCloud)
        backend.fail = true
        model.clearHistory()
        await sync.syncNow()
        XCTAssertNotNil(sync.lastError)
        XCTAssertTrue(model.continueWatching.isEmpty)
        XCTAssertGreaterThan(AppModel(defaults: defaults).historyClearedAt.timeIntervalSince1970, 0)
        backend.fail = false
        await sync.syncNow()
        XCTAssertTrue(backend.remote.records.isEmpty)
        XCTAssertTrue(model.continueWatching.isEmpty)
    }

    func testSyncOffKeepsAllProgressLocal() async throws {
        let (_, backend, sync, model) = try fixture()
        model.recordProgress(for: title("film"), position: 50, duration: 1000)
        await sync.syncNow()
        XCTAssertEqual(model.continueWatching.first?.position, 50)
        XCTAssertTrue(backend.received.isEmpty)
    }
}
#endif
