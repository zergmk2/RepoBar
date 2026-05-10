import RepoBarCore
import SwiftUI

struct RootView: View {
    @Bindable var appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            GlassBackground()
            content
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                appModel.requestRefresh()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appModel.session.account {
        case .loggedOut, .loggingIn:
            LoginView(appModel: appModel)
        case .loggedIn:
            TabView {
                NavigationStack {
                    RepoListView(appModel: appModel)
                }
                .tabItem { Label("Repos", systemImage: "square.grid.2x2") }

                NavigationStack {
                    ActivityView(appModel: appModel)
                }
                .tabItem { Label("Activity", systemImage: "bolt.heart") }

                NavigationStack {
                    StatusView(appModel: appModel)
                }
                .tabItem { Label("Status", systemImage: "gauge.with.dots.needle.67percent") }

                NavigationStack {
                    SettingsView(appModel: appModel)
                }
                .tabItem { Label("Settings", systemImage: "gearshape") }
            }
        }
    }
}
