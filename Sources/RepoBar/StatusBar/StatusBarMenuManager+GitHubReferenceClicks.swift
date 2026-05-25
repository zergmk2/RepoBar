import AppKit

extension StatusBarMenuManager {
    @objc func gitHubReferenceStatusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let shouldShowMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard shouldShowMenu == false else {
            self.showGitHubReferenceMenu(from: sender)
            return
        }

        let matches = self.appState.session.gitHubReferenceMatches
        guard matches.count > 1 else {
            self.showGitHubReferenceMenu(from: sender)
            return
        }

        self.openGitHubReferenceMatchesInIssueNavigator()
    }

    private func showGitHubReferenceMenu(from sender: Any?) {
        guard let item = self.gitHubReferenceStatusItem,
              let button = sender as? NSStatusBarButton ?? item.button
        else { return }

        item.menu = self.lazyGitHubReferenceMenu()
        button.performClick(nil)
    }
}
