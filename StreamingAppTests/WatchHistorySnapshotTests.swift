import Foundation
import XCTest
@testable import RezkaPort

final class WatchHistorySnapshotTests: XCTestCase {
    private func record(_ id: String, time: Double, position: Double = 100, season: String? = nil, episode: String? = nil) -> WatchRecord {
        WatchRecord(item: MediaItem(id: id, title: id, kind: episode == nil ? .movie : .series,
                                    genre: "Drama", synopsis: "", symbol: "film", paletteIndex: 0),
                    position: position, duration: 1000, updatedAt: Date(timeIntervalSince1970: time),
                    seasonID: season, episodeID: episode)
    }

    func testADeviceLearnsNewTitlesAndKeepsEveryEpisodeWithMostRecentTitleFirst() {
        let phone = WatchHistorySnapshot(records: [record("movie", time: 10), record("series", time: 11, season: "1", episode: "1")])
        let tablet = WatchHistorySnapshot(records: [record("new", time: 15), record("series", time: 20, season: "1", episode: "2")])
        let merged = phone.merging(tablet)
        XCTAssertEqual(merged.records.count, 4)
        XCTAssertEqual(merged.latestByTitle.map(\.item.id), ["series", "new", "movie"])
        XCTAssertEqual(merged.latestByTitle.first?.episodeID, "2")
    }

    func testANewerRewindWinsOverAnOlderLargerPosition() {
        let merged = WatchHistorySnapshot(records: [record("film", time: 20, position: 10)])
            .merging(WatchHistorySnapshot(records: [record("film", time: 10, position: 800)]))
        XCTAssertEqual(merged.records.count, 1)
        XCTAssertEqual(merged.records.first?.position, 10)
    }

    func testCompletedMovieIsRetainedInsteadOfResurrectingStaleProgress() {
        let done = WatchHistorySnapshot(records: [record("film", time: 20, position: 1000)])
        let stale = WatchHistorySnapshot(records: [record("film", time: 10)])
        XCTAssertEqual(done.merging(stale).latestByTitle.first?.progress, 1)
    }

    func testClearMarkerRejectsOfflineHistoryButKeepsPlaybackAfterClear() {
        let cleared = WatchHistorySnapshot(records: [record("new", time: 31)], clearedAt: Date(timeIntervalSince1970: 30))
        let offline = WatchHistorySnapshot(records: [record("old", time: 20), record("at-cutoff", time: 30)])
        for merged in [cleared.merging(offline), offline.merging(cleared)] {
            XCTAssertEqual(merged.records.map(\.item.id), ["new"])
            XCTAssertEqual(merged.clearedAt, cleared.clearedAt)
        }
    }

    func testEpisodeIdentityCannotCollideWithOtherTitlesOrMovieSentinels() {
        let records = [record("a:1", time: 1, season: "2", episode: "3"),
                       record("a", time: 2, season: "1:2", episode: "3"),
                       record("film", time: 3), record("film", time: 4, season: "movie", episode: "movie")]
        XCTAssertEqual(Set(records.map(\.syncKey)).count, 4)
        XCTAssertEqual(WatchHistorySnapshot(records: records).merging(.init()).records.count, 4)
    }

    func testHistoryLimitAndTiedDatesHaveStableOrdering() {
        let records = (0..<510).map { record(String($0), time: Double($0 / 2 + 1)) }
        let first = WatchHistorySnapshot(records: records).merging(.init())
        let second = WatchHistorySnapshot(records: records.reversed()).merging(.init())
        XCTAssertEqual(first.records.count, 500)
        XCTAssertEqual(first.records.map(\.syncKey), second.records.map(\.syncKey))
    }

    func testUnreadableProgressDoesNotReplaceValidRecords() {
        let invalid = [record("negative", time: 20, position: -1), record("nan", time: 20, position: .nan)]
        XCTAssertEqual(WatchHistorySnapshot(records: invalid + [record("valid", time: 10)]).merging(.init()).records.map(\.item.id), ["valid"])
    }
}
