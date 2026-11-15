import SwiftUI

@main
struct RezkaPortApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainTabsView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(AppColors.accent)
        }
    }
}

struct MainTabsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection: Binding(get: { model.selectedTab }, set: { model.selectedTab = $0 })) {
            NavigationStack {
                HomeView()
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(0)

            NavigationStack {
                SearchView()
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(1)

            NavigationStack {
                FavoritesView()
            }
            .tabItem { Label("Saved", systemImage: "bookmark.fill") }
            .tag(2)

            NavigationStack {
                DownloadsView()
            }
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            .tag(3)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(4)
        }
        .toolbarBackground(.automatic, for: .tabBar)
        .sensoryFeedback(.selection, trigger: model.selectedTab)
        .task(id: model.excludedCountryCodes) { await model.checkCatalogueCountries() }
        .sheet(isPresented: Binding(get: { model.browser.isPresented }, set: { if !$0 { model.browser.cancel() } })) {
            RezkaVerificationView(session: model.browser)
        }
        .task {
            #if DEBUG
            try? await Task.sleep(for: .seconds(2))
            RezkaLayoutDiagnostics.capture()
            if ProcessInfo.processInfo.arguments.contains("--rezka-playback-probe") {
                await RezkaPlaybackDiagnostics.probe(source: model.contentSource)
            }
            #endif
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Also detects changes while Home remains open on another device.
            while !Task.isCancelled {
                await model.refreshCloudHistory()
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                guard phase == .background else { return }
                let background = WatchHistoryBackgroundTask {
                    model.watchSync.cancelCurrentSync()
                }
                defer { background.finish() }
                await model.syncHistoryBeforeLeaving()
            }
        }
    }
}

/// Give the final playback save bounded time to upload when the app backgrounds.
@MainActor
private final class WatchHistoryBackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(onExpiration: @escaping @MainActor () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save viewing history") { [weak self] in
            Task { @MainActor in
                onExpiration()
                self?.finish()
            }
        }
    }

    func finish() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
