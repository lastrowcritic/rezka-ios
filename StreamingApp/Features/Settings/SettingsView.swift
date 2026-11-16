import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingClearHistoryAlert = false
    @State private var mirrorHost = ""
    @State private var syncEmail = ""
    @State private var syncPassword = ""
    @State private var syncMode = "login"
    @State private var syncBusy = false
    @State private var syncError: String?
    @State private var syncServer = ""

    private let qualities = ["Auto", "2160p", "1440p", "1080p", "720p", "480p", "360p"]

    var body: some View {
        List {
            Section("Rezka website") {
                LabeledContent("Current mirror", value: model.activeMirror)
                TextField("Mirror domain", text: $mirrorHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Use this mirror") { Task { await model.selectMirror(mirrorHost) } }
                    .disabled(mirrorHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("The app chooses a working mirror automatically. You can enter another domain here.")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            Section("Catalogue preferences") {
                NavigationLink {
                    ExcludedCountriesView()
                } label: {
                    LabeledContent("Excluded countries", value: model.excludedCountryCodes.isEmpty ? "None" : "\(model.excludedCountryCodes.count) selected")
                }
                .accessibilityIdentifier("excluded-countries")
                Text("Hide titles made in countries you choose from the catalogue and search results.")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            Section("Playback") {
                Picker("Default quality", selection: Binding(
                    get: { model.preferredQuality },
                    set: { model.preferredQuality = $0 }
                )) {
                    ForEach(qualities, id: \.self) { quality in
                        Text(quality).tag(quality)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Auto play next episode", isOn: Binding(
                    get: { model.autoPlayNext },
                    set: { model.autoPlayNext = $0 }
                ))

                NavigationLink {
                    HistoryView()
                } label: {
                    Label("Watch history", systemImage: "clock.arrow.circlepath")
                }
            }

            Section("Library") {
                LabeledContent("Saved titles", value: "\(model.favorites.count)")
                LabeledContent("Offline videos", value: "\(model.downloadedItems.count)")
                Button("Clear watch history", role: .destructive) {
                    showingClearHistoryAlert = true
                }
            }

            Section("Sync across devices") {
                Picker("Sync with", selection: Binding(
                    get: { model.watchSync.mode },
                    set: { next in
                        Task {
                            syncBusy = true
                            syncError = nil
                            defer { syncBusy = false }
                            await model.watchSync.selectMode(next)
                        }
                    }
                )) {
                    ForEach(WatchSyncMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .accessibilityIdentifier("sync-provider")
                .disabled(syncBusy)
                Text("Sync watch history, each episode’s position, and Continue Watching. The most recently watched titles appear first on every device.")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
                if model.watchSync.mode == .appleCloud {
                    Text(WatchSyncManager.appleCloudAvailable
                         ? "Uses your private iCloud account. Sign in to the same Apple Account on each device."
                         : "Apple Cloud is unavailable in this build. You can use a custom server instead.")
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                }
                if model.watchSync.mode == .server {
                    TextField("https://sync.example.com", text: $syncServer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel("Sync server address")
                    Button("Use this server") {
                        Task {
                            syncBusy = true
                            syncError = nil
                            defer { syncBusy = false }
                            do {
                                try await model.watchSync.setServer(syncServer)
                                syncServer = model.watchSync.serverClient.server?.absoluteString ?? ""
                            } catch { syncError = error.localizedDescription }
                        }
                    }
                    .disabled(syncBusy || syncServer == (model.watchSync.serverClient.server?.absoluteString ?? ""))
                    Text("Enter the HTTPS address of your Rezka sync server, then sign in with the same account on each device.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    if model.watchSync.serverClient.server != nil, let email = model.watchSync.serverClient.email {
                        LabeledContent("Signed in", value: email)
                        Button("Sign out") {
                            Task { await model.watchSync.signOut() }
                        }
                        .disabled(syncBusy)
                    } else if model.watchSync.serverClient.server != nil {
                        TextField("Email", text: $syncEmail)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                        SecureField("Password", text: $syncPassword)
                            .textContentType(syncMode == "login" ? .password : .newPassword)
                        Text("Use the same account on each device. Passwords are protected and are never stored in the app.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        Button(syncBusy ? "Connecting" : syncMode == "login" ? "Sign in" : "Create account") {
                            Task {
                                syncBusy = true
                                syncError = nil
                                defer { syncBusy = false }
                                do {
                                    try await model.watchSync.authenticate(mode: syncMode, email: syncEmail, password: syncPassword)
                                    syncPassword = ""
                                } catch { syncError = error.localizedDescription }
                            }
                        }
                        .disabled(syncBusy || syncEmail.isEmpty || syncPassword.count < 10)
                        Button(syncMode == "login" ? "Create an account" : "I already have an account") {
                            syncMode = syncMode == "login" ? "register" : "login"
                            syncError = nil
                        }
                        .disabled(syncBusy)
                    }
                }
                if model.watchSync.mode != .off {
                    Button(model.watchSync.isSyncing ? "Syncing…" : "Sync now") {
                        Task { await model.syncHistoryNow() }
                    }
                    .disabled(syncBusy || model.watchSync.isSyncing)
                    .accessibilityIdentifier("sync-now")
                }
                if let status = syncError ?? model.watchSync.lastError ?? (model.watchSync.status.isEmpty ? nil : model.watchSync.status) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(syncError == nil && model.watchSync.lastError == nil ? AppColors.secondaryText : .red)
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.10")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "12")
                Text("Rezka catalogue and video library for iPhone")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .onAppear { syncServer = model.watchSync.serverClient.server?.absoluteString ?? "" }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog("Clear all watch history?", isPresented: $showingClearHistoryAlert, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears watch history and playback progress on this device and devices using the selected sync account. Offline devices apply the change when they reconnect.")
        }
    }
}

struct ExcludedCountriesView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    private var countries: [MediaCountry] {
        MediaCountry.all.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                if !model.excludedCountryCodes.isEmpty {
                    Button("Show all countries") { model.excludedCountryCodes = [] }
                        .accessibilityIdentifier("clear-country-exclusions")
                }
            } footer: {
                Text("Titles made in any selected country are hidden from Home, search, categories and collections. This also hides co-productions. Your saved titles and downloads stay available.")
            }
            Section("Countries to exclude") {
                ForEach(countries) { country in
                    Toggle(country.name, isOn: Binding(
                        get: { model.excludedCountryCodes.contains(country.id) },
                        set: { excluded in
                            if excluded { model.excludedCountryCodes.insert(country.id) }
                            else { model.excludedCountryCodes.remove(country.id) }
                        }
                    ))
                    .tint(AppColors.accent)
                    .accessibilityIdentifier("exclude-country-\(country.id)")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .navigationTitle("Excluded countries")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a country")
    }
}
