#if os(iOS)
import AVFoundation
import XCTest
@testable import RezkaPort

@MainActor
final class PlaybackHistoryTests: XCTestCase {
    func testNativePlayerReceivesReadyStatusAndSeeksWhileConsumerIsSuspended() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "NativePlayerFixture", withExtension: "mp4"))
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let resumed = expectation(description: "Native player restores saved position")
        let task = Task { @MainActor in
            for await status in PlayerView.itemStatusUpdates(for: item).values {
                guard !Task.isCancelled else { return }
                if status == .unknown {
                    // Let KVO deliver readiness while AsyncPublisher has no demand.
                    try? await Task.sleep(for: .milliseconds(500))
                } else if status == .readyToPlay {
                    let success = await player.seek(to: CMTime(seconds: 12.5, preferredTimescale: 600),
                                                    toleranceBefore: .zero, toleranceAfter: .zero)
                    XCTAssertTrue(success)
                    XCTAssertEqual(player.currentTime().seconds, 12.5, accuracy: 0.1)
                    resumed.fulfill()
                    return
                } else if status == .failed {
                    XCTFail(item.error?.localizedDescription ?? "Fixture playback failed")
                    resumed.fulfill()
                    return
                }
            }
        }
        defer { task.cancel(); player.pause() }
        player.play()
        await fulfillment(of: [resumed], timeout: 10)
    }

    func testCountryExclusionsPersistAndKeepSavedTitlesAvailable() throws {
        let suite = "RezkaCountryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        let coProduction = MediaItem(id: "us-ru", title: "Co-production", kind: .movie, genre: "Drama", synopsis: "", symbol: "film", paletteIndex: 0, countryCodes: ["US", "RU"])
        let italian = MediaItem(id: "it", title: "Italian title", kind: .movie, genre: "Drama", synopsis: "", symbol: "film", paletteIndex: 0, countryCodes: ["IT"])
        model.upsert(coProduction)
        model.upsert(italian)
        model.toggleFavorite(coProduction)
        model.excludedCountryCodes = ["RU"]
        XCTAssertEqual(model.items.map(\.id), ["it"])
        XCTAssertEqual(model.favorites.map(\.id), ["us-ru"])
        XCTAssertEqual(model.visibleItems([coProduction, italian]).map(\.id), ["it"])
        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.excludedCountryCodes, ["RU"])
        XCTAssertEqual(restored.items.map(\.id), ["it"])
        restored.excludedCountryCodes = []
        XCTAssertEqual(restored.items.count, 2)
    }
    func testPlaybackStartKeepsSavedEpisodeAndRelaunchRestoresExactPosition() throws {
        let suite = "RezkaHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = MediaItem(id: "42", title: "Episode test", kind: .series, genre: "Drama", synopsis: "", symbol: "tv", paletteIndex: 0)
        let request = PlaybackRequest(mediaID: "42", translatorID: "7", season: "2", episode: "3")
        let model = AppModel(defaults: defaults)
        model.recordProgress(for: item, position: 754.25, duration: 2400, request: request)
        model.recordStart(item)
        XCTAssertEqual(model.history.first?.translatorID, "7")
        XCTAssertEqual(model.history.first?.resumePosition(for: request), 754.25)
        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.history.first?.resumePosition(for: request), 754.25)
        XCTAssertEqual(restored.continueWatching.count, 1)
        restored.recordProgress(for: item, position: 900, duration: .nan, request: request)
        XCTAssertEqual(restored.history.first?.duration, 2400)
        XCTAssertEqual(restored.history.first?.position, 900)
        restored.recordProgress(for: item, position: 2400, duration: 2400, request: request)
        XCTAssertEqual(restored.episodeRecord(mediaID: "42", season: "2", episode: "3")?.progress, 1)
        let next = PlaybackRequest(mediaID: "42", translatorID: "7", season: "2", episode: "4")
        restored.recordProgress(for: item, position: 0, duration: 0, request: next)
        XCTAssertEqual(restored.history.first?.episodeID, "4")
        XCTAssertEqual(restored.history.first?.duration, 0)
        XCTAssertEqual(restored.continueWatching.count, 1)
        let relaunched = AppModel(defaults: defaults)
        XCTAssertEqual(relaunched.episodeRecord(mediaID: "42", season: "2", episode: "3")?.progress, 1)
        XCTAssertEqual(relaunched.history.first?.episodeID, "4")
    }
}
#endif
