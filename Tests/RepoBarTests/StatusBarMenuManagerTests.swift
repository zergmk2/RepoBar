import AppKit
@testable import RepoBar
import RepoBarCore
import Testing

struct StatusBarMenuManagerTests {
    @MainActor
    @Test
    func `main status item uses native AppKit menu`() throws {
        let manager = StatusBarMenuManager(appState: AppState(), statusBar: NSStatusBar())

        manager.ensureStatusItems()

        let item = try #require(manager.statusItem)
        let button = try #require(item.button)
        #expect(item.menu != nil)
        #expect(item.autosaveName != "repobar-main")
        #expect(button.isEnabled)
        #expect(!self.containsHostingView(button))
    }

    @MainActor
    @Test
    func `keyboard reference status item is hidden instead of recreated`() throws {
        let appState = AppState()
        let manager = StatusBarMenuManager(appState: appState, statusBar: NSStatusBar())
        appState.session.keyboardIssueMatch = try self.makeMatch()

        manager.syncKeyboardIssueStatusItemForTesting()

        let item = try #require(manager.keyboardIssueStatusItemForTesting())
        let menu = try #require(manager.keyboardIssueMenuForTesting())
        #expect(item.isVisible)
        #expect(item.menu === menu)
        #expect(item.autosaveName != "repobar-github-reference")
        let button = try #require(item.button)
        #expect(button.isEnabled)
        #expect(!self.containsHostingView(button))
        #expect(menu.items.contains { $0.title == "Open #42 in Browser" })
        #expect(menu.items.contains { $0.view is MenuItemHostingView })
        #expect(button.title.contains("#42 Open owner/repo"))

        appState.session.keyboardIssueMatch = nil
        manager.syncKeyboardIssueStatusItemForTesting()

        #expect(manager.keyboardIssueStatusItemForTesting() === item)
        #expect(!item.isVisible)
        #expect(manager.keyboardIssueMenuForTesting() === menu)
    }

    private func makeMatch() throws -> GitHubReferenceMatch {
        try GitHubReferenceMatch(
            query: .issueNumber(42),
            title: "Fix the menu click path when the watcher is enabled",
            url: #require(URL(string: "https://github.com/owner/repo/issues/42")),
            repositoryFullName: "owner/repo",
            kind: .issue,
            state: .open,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20)
        )
    }

    @MainActor
    private func containsHostingView(_ view: NSView?) -> Bool {
        guard let view else { return false }

        if String(describing: type(of: view)).contains("HostingView") {
            return true
        }
        return view.subviews.contains { self.containsHostingView($0) }
    }
}
