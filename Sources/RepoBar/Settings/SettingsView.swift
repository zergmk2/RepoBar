import AppKit
import RepoBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var session: Session
    let appState: AppState
    @State private var contentWidth = SettingsTab.general.preferredWidth
    @State private var contentHeight = SettingsTab.general.preferredHeight

    var body: some View {
        TabView(selection: self.$session.settingsSelectedTab) {
            GeneralSettingsView(session: self.session, appState: self.appState)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)
            DisplaySettingsView(session: self.session, appState: self.appState)
                .tabItem { Label("Display", systemImage: "rectangle.3.group") }
                .tag(SettingsTab.display)
            RepoSettingsView(session: self.session, appState: self.appState)
                .tabItem { Label("Repositories", systemImage: "tray.full") }
                .tag(SettingsTab.repositories)
            AccountSettingsView(session: self.session, appState: self.appState)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(SettingsTab.accounts)
            NotificationSettingsView(session: self.session, appState: self.appState)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
                .tag(SettingsTab.notifications)
            AdvancedSettingsView(session: self.session, appState: self.appState)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.advanced)
            #if DEBUG
                if self.session.settings.debugPaneEnabled {
                    DebugSettingsView(session: self.session, appState: self.appState)
                        .tabItem { Label("Debug", systemImage: "ant.fill") }
                        .tag(SettingsTab.debug)
                }
            #endif
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .tabViewStyle(.automatic)
        .frame(width: self.contentWidth, height: self.contentHeight)
        .onAppear {
            self.updateLayout(for: self.session.settingsSelectedTab, animate: false)
        }
        .onChange(of: self.session.settingsSelectedTab) { _, newValue in
            self.updateLayout(for: newValue, animate: true)
        }
        .onChange(of: self.session.settings.debugPaneEnabled) { _, enabled in
            #if DEBUG
                if !enabled, self.session.settingsSelectedTab == .debug {
                    self.session.settingsSelectedTab = .general
                }
            #endif
        }
    }

    private func updateLayout(for tab: SettingsTab, animate: Bool) {
        let change = {
            self.contentWidth = tab.preferredWidth
            self.contentHeight = tab.preferredHeight
        }
        if animate {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { change() }
        } else {
            change()
        }
        Self.resizeSettingsWindow(width: tab.preferredWidth, height: tab.preferredHeight, animate: animate)
    }

    private static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"

    private static var knownTabTitles: Set<String> {
        var titles = [
            SettingsTab.general.title,
            SettingsTab.display.title,
            SettingsTab.repositories.title,
            SettingsTab.accounts.title,
            SettingsTab.notifications.title,
            SettingsTab.advanced.title,
            SettingsTab.about.title
        ]
        #if DEBUG
            titles.append(SettingsTab.debug.title)
        #endif
        return Set(titles)
    }

    private static func resizeSettingsWindow(width: CGFloat, height: CGFloat, animate: Bool) {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == self.settingsWindowIdentifier
                || self.knownTabTitles.contains($0.title)
        }) else { return }

        let toolbarHeight = window.frame.height - window.contentLayoutRect.height
        guard toolbarHeight > 0 else { return }

        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
        let contentSize = SettingsWindowSizing.clampedContentSize(
            desired: NSSize(width: width, height: height),
            visibleFrame: visibleFrame,
            chrome: window.frameRect(forContentRect: .zero).size
        )

        // Establish resizability bounds once, derived from the actual chrome so the user
        // can drag the window edge to a sensible size but never past the screen.
        window.contentMinSize = SettingsWindowSizing.minimumContentSize(
            for: SettingsTab.minimumContentSize,
            chrome: window.frameRect(forContentRect: .zero).size
        )
        if let visibleFrame {
            window.contentMaxSize = SettingsWindowSizing.maximumContentSize(
                for: visibleFrame,
                chrome: window.frameRect(forContentRect: .zero).size
            )
        }

        let newSize = NSSize(
            width: contentSize.width,
            height: contentSize.height + toolbarHeight
        )
        var frame = window.frame
        let oldSize = frame.size
        frame.size = newSize
        // Anchor the top edge so the title bar doesn't jump when switching tabs, but never
        // push the bottom below the screen's visible area.
        frame.origin.y += oldSize.height - newSize.height
        if let visibleFrame {
            frame.origin.y = SettingsWindowSizing.clampedWindowOriginY(
                proposedOriginY: frame.origin.y,
                windowHeight: newSize.height,
                visibleFrame: visibleFrame
            )
        }
        window.setFrame(frame, display: true, animate: animate)
    }
}

/// Pure helpers for sizing the Settings window. Kept AppKit-free at the core so we can unit
/// test the clamping logic without standing up an `NSWindow` in tests.
enum SettingsWindowSizing {
    /// Clamp a desired content size so its enclosing frame (content + chrome) fits inside
    /// `visibleFrame` (i.e. the screen area not covered by the menu bar or Dock). Returns the
    /// desired size unchanged when no visible frame is available.
    static func clampedContentSize(
        desired: NSSize,
        visibleFrame: NSRect?,
        chrome: NSSize = .zero
    ) -> NSSize {
        guard let visibleFrame else { return desired }

        let chromeWidth = max(0, chrome.width)
        let chromeHeight = max(0, chrome.height)
        let maxWidth = max(1, visibleFrame.width - chromeWidth)
        let maxHeight = max(1, visibleFrame.height - chromeHeight)
        return NSSize(
            width: min(desired.width, maxWidth),
            height: min(desired.height, maxHeight)
        )
    }

    /// The absolute minimum content size the window should allow. The chrome is added back
    /// because AppKit's `contentMinSize` is in content coordinates, not window-frame coords.
    static func minimumContentSize(
        for minimum: NSSize,
        chrome: NSSize
    ) -> NSSize {
        let chromeWidth = max(0, chrome.width)
        let chromeHeight = max(0, chrome.height)
        return NSSize(
            width: max(minimum.width - chromeWidth, 1),
            height: max(minimum.height - chromeHeight, 1)
        )
    }

    /// AppKit expects `contentMaxSize` in content coordinates, so remove the window chrome
    /// from the screen's visible frame before applying the resize limit.
    static func maximumContentSize(
        for visibleFrame: NSRect,
        chrome: NSSize
    ) -> NSSize {
        let chromeWidth = max(0, chrome.width)
        let chromeHeight = max(0, chrome.height)
        return NSSize(
            width: max(visibleFrame.width - chromeWidth, 1),
            height: max(visibleFrame.height - chromeHeight, 1)
        )
    }

    static func clampedWindowOriginY(
        proposedOriginY: CGFloat,
        windowHeight: CGFloat,
        visibleFrame: NSRect
    ) -> CGFloat {
        let minimumOriginY = visibleFrame.minY
        let maximumOriginY = max(minimumOriginY, visibleFrame.maxY - max(windowHeight, 0))
        return min(max(proposedOriginY, minimumOriginY), maximumOriginY)
    }
}
