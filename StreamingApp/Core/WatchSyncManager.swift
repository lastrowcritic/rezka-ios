import Foundation
import Observation

@MainActor
protocol WatchHistorySyncBackend {
    func exchange(_ local: WatchHistorySnapshot) async throws -> WatchHistorySnapshot
}

extension ServerWatchSyncClient: WatchHistorySyncBackend {}

/// One serialized sync loop owns both transports. Late replies cannot replace new
/// playback, and selecting another provider invalidates work from the old one.
@MainActor
@Observable
final class WatchSyncManager {
    private let defaults: UserDefaults
    let serverClient: ServerWatchSyncClient
    private(set) var mode: WatchSyncMode
    private(set) var status = ""
    private(set) var lastError: String?
    private(set) var isSyncing = false
    @ObservationIgnored private var readLocal: (() -> WatchHistorySnapshot)?
    @ObservationIgnored private var install: ((WatchHistorySnapshot) -> Void)?
    @ObservationIgnored private var flight: Task<Void, Never>?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var needsSync = false
    private var generation = 0
    @ObservationIgnored private let appleBackend: (any WatchHistorySyncBackend)?

    static var appleCloudAvailable: Bool {
        #if REZKA_CLOUDKIT
        true
        #else
        false
        #endif
    }

    init(defaults: UserDefaults = .standard, appleBackend: (any WatchHistorySyncBackend)? = nil) {
        self.defaults = defaults
        serverClient = ServerWatchSyncClient(defaults: defaults)
        mode = defaults.string(forKey: "watchSyncMode").flatMap(WatchSyncMode.init(rawValue:))
            ?? (defaults.string(forKey: "syncServer") == nil ? .off : .server)
        #if REZKA_CLOUDKIT
        self.appleBackend = appleBackend ?? AppleCloudWatchSyncClient(defaults: defaults)
        #else
        self.appleBackend = appleBackend
        #endif
    }

    func connect(read: @escaping () -> WatchHistorySnapshot, install: @escaping (WatchHistorySnapshot) -> Void) {
        readLocal = read
        self.install = install
    }

    func selectMode(_ next: WatchSyncMode) async {
        guard next != mode else { return }
        await stopCurrentWork()
        mode = next
        defaults.set(next.rawValue, forKey: "watchSyncMode")
        lastError = nil
        status = next == .off ? "Viewing history is saved on this device." : "Connecting…"
        #if REZKA_CLOUDKIT
        if next == .appleCloud { defaults.removeObject(forKey: "watchSyncAppleAccount") }
        #endif
        await syncNow()
    }

    func setServer(_ address: String) async throws {
        await stopCurrentWork()
        try await serverClient.setServer(address)
        lastError = nil
        status = serverClient.status
        await syncNow()
    }

    func authenticate(mode: String, email: String, password: String) async throws {
        await stopCurrentWork()
        try await serverClient.authenticate(mode: mode, email: email, password: password)
        await syncNow()
    }

    func signOut() async {
        await stopCurrentWork()
        await serverClient.signOut()
        status = serverClient.status
        lastError = nil
    }

    func schedule() {
        guard mode != .off else { return }
        needsSync = true
        guard scheduled == nil else { return }
        scheduled = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.scheduled = nil
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard mode != .off, readLocal != nil else { return }
        scheduled?.cancel()
        scheduled = nil
        needsSync = true
        if let flight { await flight.value; return }
        let current = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            isSyncing = true
            defer {
                isSyncing = false
                flight = nil
            }
            while needsSync, current == generation, !Task.isCancelled {
                needsSync = false
                do {
                    guard let local = readLocal?() else { return }
                    let remote: WatchHistorySnapshot
                    switch mode {
                    case .off: return
                    case .server: remote = try await serverClient.exchange(local)
                    case .appleCloud:
                        guard let appleBackend else {
                            throw NSError(domain: "WatchSync", code: -4, userInfo: [NSLocalizedDescriptionKey: "Apple Cloud is unavailable in this build. Choose a custom server, or install a build with iCloud enabled."])
                        }
                        remote = try await appleBackend.exchange(local)
                    }
                    try Task.checkCancellation()
                    guard current == generation, let latest = readLocal?() else { return }
                    install?(latest.merging(remote))
                    status = "Viewing history and Continue Watching are up to date."
                    lastError = nil
                } catch {
                    guard current == generation, !Task.isCancelled else { return }
                    lastError = error.localizedDescription
                    status = "Sync needs attention. Your viewing history is saved on this device."
                    #if REZKA_CLOUDKIT
                    if case AppleCloudWatchSyncClient.AccountError.changed = error {
                        mode = .off
                        defaults.set(mode.rawValue, forKey: "watchSyncMode")
                    }
                    #endif
                    return // Launch, foreground polling, or a new save retries durable local data.
                }
            }
        }
        flight = task
        await task.value
    }

    func cancelCurrentSync() {
        generation += 1
        scheduled?.cancel()
        scheduled = nil
        needsSync = false
        flight?.cancel()
    }

    private func stopCurrentWork() async {
        let previous = flight
        cancelCurrentSync()
        await previous?.value
    }
}
