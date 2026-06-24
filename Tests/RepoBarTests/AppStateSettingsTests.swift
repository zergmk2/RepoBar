import Foundation
@testable import RepoBar
import RepoBarCore
import Testing

@MainActor
struct AppStateSettingsTests {
    @Test
    func `setting update persists nested value without starting runtime`() throws {
        let suiteName = "com.steipete.repobar.settings-update-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let appState = AppState(settingsStore: store)

        appState.updateSetting(\.repoList.displayLimit, to: 12)

        #expect(appState.session.settings.repoList.displayLimit == 12)
        #expect(store.load().repoList.displayLimit == 12)
        #expect(appState.isStarted == false)
    }

    @Test
    func `heatmap setting effect updates derived range`() throws {
        let suiteName = "com.steipete.repobar.settings-update-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(settingsStore: SettingsStore(defaults: defaults))
        let previousRange = appState.session.heatmapRange

        appState.updateSetting(\.heatmap.span, to: .oneMonth, effects: .heatmapRange)

        #expect(appState.session.heatmapRange != previousRange)
        #expect(appState.session.settings.heatmap.span == .oneMonth)
    }

    @Test
    func `bootstrap keeps gitlab repository client active`() async throws {
        let suiteName = "com.steipete.repobar.settings-update-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let account = Account(
            provider: .gitlab,
            username: "alice",
            host: try #require(URL(string: "https://gitlab.example.com")),
            authMethod: .pat
        )
        var settings = UserSettings()
        settings.accounts = [account]
        settings.activeAccountID = account.id
        store.save(settings)
        let appState = AppState(settingsStore: store)

        await appState.bootstrapAccounts()

        #expect(appState.activeProvider == .gitlab)
        #expect(appState.repositoryClient is GitLabClient)
    }
}
