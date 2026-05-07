import AppKit
import Logging
import OSLog
import RepoBarCore

@MainActor
final class StatusBarMenuManager: NSObject, NSMenuDelegate {
    private static let minimumMainMenuItems = 3
    let appState: AppState
    private let statusBar: NSStatusBar
    private var mainMenu: NSMenu?
    var statusItem: NSStatusItem?
    var keyboardIssueStatusItem: NSStatusItem?
    private var keyboardIssueMenu: NSMenu?
    private lazy var menuBuilder = StatusBarMenuBuilder(appState: self.appState, target: self)
    private let menuItemFactory = MenuItemViewFactory()
    lazy var recentMenuService = RecentMenuService(github: self.appState.github)
    private lazy var recentListCoordinator = RecentListMenuCoordinator(
        appState: self.appState,
        menuBuilder: self.menuBuilder,
        menuItemFactory: self.menuItemFactory,
        menuService: self.recentMenuService,
        actionHandler: self
    )
    lazy var localGitMenuCoordinator = LocalGitMenuCoordinator(
        appState: self.appState,
        menuBuilder: self.menuBuilder,
        menuItemFactory: self.menuItemFactory,
        recentMenuService: self.recentMenuService,
        actionHandler: self
    )
    lazy var changelogMenuCoordinator = ChangelogMenuCoordinator(
        appState: self.appState,
        menuBuilder: self.menuBuilder,
        menuItemFactory: self.menuItemFactory
    )
    lazy var activityMenuCoordinator = ActivityMenuCoordinator(
        appState: self.appState,
        menuBuilder: self.menuBuilder,
        actionHandler: self
    )
    private let signposter = OSSignposter(subsystem: "com.steipete.repobar", category: "menu")
    private let logger = RepoBarLogging.logger("menu-state")
    private weak var menuResizeWindow: NSWindow?
    private var lastMainMenuWidth: CGFloat?
    private var lastMainMenuSignature: MenuBuildSignature?
    private var lastMainMenuWidthSignature: MenuBuildSignature?
    private var pendingMenuReopen = false
    var webURLBuilder: RepoWebURLBuilder {
        RepoWebURLBuilder(host: self.appState.session.settings.githubHost)
    }

    private weak var checkoutProgressWindow: NSWindow?

    init(appState: AppState, statusBar: NSStatusBar = .system) {
        self.appState = appState
        self.statusBar = statusBar
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.menuFiltersChanged),
            name: .menuFiltersDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.menuRepositoriesChanged),
            name: .menuRepositoriesDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.menuRepositoriesChanged),
            name: .menuDiagnosticsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.recentListFiltersChanged),
            name: .recentListFiltersDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.keyboardIssueMatchChanged),
            name: .keyboardIssueMatchDidChange,
            object: nil
        )
    }

    var isAttached: Bool {
        self.statusItem != nil
    }

    func ensureStatusItems() {
        if self.statusItem == nil {
            let item = self.statusBar.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "repobar-main"
            item.isVisible = true
            item.button?.imageScaling = .scaleNone
            self.attachMainMenu(to: item)
            return
        }
    }

    func attachMainMenu(to statusItem: NSStatusItem) {
        let menu = self.mainMenu ?? self.menuBuilder.makeMainMenu()
        self.mainMenu = menu
        menu.delegate = self
        self.statusItem = statusItem
        statusItem.length = NSStatusItem.variableLength
        statusItem.menu = menu
        statusItem.button?.isEnabled = true
        self.applyStatusItemAppearance()
        DispatchQueue.main.async { [weak self] in
            self?.applyStatusItemAppearance()
        }
        self.prepareMainMenuIfNeeded(menu)
        self.logMenuEvent("attachMainMenu statusItem=\(self.objectID(statusItem)) menuItems=\(menu.items.count)")
    }

    func requestMenuReopenAfterClose() {
        self.pendingMenuReopen = true
    }

    // MARK: - Menu actions

    @objc func refreshNow() {
        self.appState.requestRefresh(cancelInFlight: true)
    }

    @objc func openPreferences() {
        SettingsOpener.shared.open()
    }

    @objc func openAbout() {
        self.appState.session.settingsSelectedTab = .about
        SettingsOpener.shared.open()
    }

    @objc func checkForUpdates() {
        SparkleController.shared.checkForUpdates()
    }

    @objc func menuFiltersChanged() {
        guard let menu = self.mainMenu else { return }

        // Defer menu rebuild to next run loop to avoid modifying menu during layout
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.recentListCoordinator.pruneMenus()
            self.appState.persistSettings()
            let plan = self.menuBuilder.mainMenuPlan()
            self.menuBuilder.populateMainMenu(menu, repos: plan.repos)
            self.lastMainMenuSignature = plan.signature
            self.menuBuilder.refreshMenuViewHeights(in: menu)
            menu.update()
        }
    }

    @objc private func menuRepositoriesChanged() {
        guard let menu = self.mainMenu else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.applyStatusItemAppearance()
            let plan = self.menuBuilder.mainMenuPlan()
            guard self.lastMainMenuSignature != plan.signature else { return }

            self.recentListCoordinator.pruneMenus()
            self.localGitMenuCoordinator.pruneMenus()
            self.changelogMenuCoordinator.pruneMenus()
            self.menuBuilder.populateMainMenu(menu, repos: plan.repos)
            self.lastMainMenuSignature = plan.signature
            self.lastMainMenuWidthSignature = nil
            if let width = self.lastMainMenuWidth {
                self.menuBuilder.refreshMenuViewHeights(in: menu, width: width)
            } else {
                self.menuBuilder.refreshMenuViewHeights(in: menu)
            }
            menu.update()
        }
    }

    @objc private func recentListFiltersChanged() {
        self.recentListCoordinator.handleFilterChanges()
    }

    @objc private func keyboardIssueMatchChanged() {
        self.syncKeyboardIssueStatusItem()
    }

    private func syncKeyboardIssueStatusItem() {
        guard let match = self.appState.session.keyboardIssueMatch else {
            self.removeKeyboardIssueStatusItem()
            return
        }

        let item = self.lazyKeyboardIssueStatusItem()
        let menu = self.lazyKeyboardIssueMenu()
        self.populateKeyboardIssueMenu(menu, match: match)
        item.length = NSStatusItem.variableLength
        item.menu = menu
        if let button = item.button {
            button.isEnabled = true
            button.image = NSImage(systemSymbolName: self.keyboardIssueSystemImage(for: match), accessibilityDescription: match.kind.label)
            button.image?.isTemplate = true
            button.imageScaling = .scaleNone
            self.setButtonTitle(self.keyboardIssueTitle(for: match), for: button)
            button.toolTip = self.keyboardIssueMenuTitle(for: match)
        }
        item.isVisible = true
    }

    private func lazyKeyboardIssueStatusItem() -> NSStatusItem {
        if let item = self.keyboardIssueStatusItem {
            return item
        }

        let item = self.statusBar.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "repobar-github-reference"
        item.button?.imageScaling = .scaleNone
        self.keyboardIssueStatusItem = item
        return item
    }

    private func removeKeyboardIssueStatusItem() {
        self.keyboardIssueMenu = nil
        guard let item = self.keyboardIssueStatusItem else { return }

        item.menu = nil
        item.button?.image = nil
        item.button?.title = ""
        self.keyboardIssueStatusItem = nil
        self.statusBar.removeStatusItem(item)
    }

    private func lazyKeyboardIssueMenu() -> NSMenu {
        if let menu = self.keyboardIssueMenu {
            return menu
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        self.keyboardIssueMenu = menu
        return menu
    }

    private func populateKeyboardIssueMenu(_ menu: NSMenu, match: GitHubReferenceMatch) {
        menu.removeAllItems()

        let openTitle = "Open \(match.query.displayText) in Browser"
        let openItem = NSMenuItem(title: openTitle, action: #selector(self.openKeyboardIssueMatch(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = match.url
        openItem.image = NSImage(systemSymbolName: self.keyboardIssueSystemImage(for: match), accessibilityDescription: match.kind.label)
        openItem.image?.isTemplate = true
        menu.addItem(openItem)

        let titleItem = NSMenuItem(title: self.keyboardIssueMenuTitle(for: match), action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let repoItem = NSMenuItem(title: match.repositoryFullName, action: nil, keyEquivalent: "")
        repoItem.isEnabled = false
        menu.addItem(repoItem)

        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "Copy URL", action: #selector(self.copyKeyboardIssueURL(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = match.url
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy URL")
        copyItem.image?.isTemplate = true
        menu.addItem(copyItem)
    }

    private func keyboardIssueMenuTitle(for match: GitHubReferenceMatch) -> String {
        let state = match.state.map { "\($0.label) " } ?? ""
        let kind = match.kind.label
        return "\(state)\(kind): \(match.title)"
    }

    private func refreshKeyboardIssueMenuIfNeeded(_ menu: NSMenu) {
        guard menu === self.keyboardIssueMenu,
              let match = self.appState.session.keyboardIssueMatch
        else {
            return
        }

        self.populateKeyboardIssueMenu(menu, match: match)
    }

    private func keyboardIssueSystemImage(for match: GitHubReferenceMatch) -> String {
        switch match.kind {
        case .issue:
            match.state == .closed ? "checkmark.circle" : "exclamationmark.circle"
        case .pullRequest:
            match.state == .closed ? "arrow.triangle.merge" : "arrow.triangle.branch.circle"
        case .commit:
            "number.square"
        }
    }

    private func keyboardIssueTitle(for match: GitHubReferenceMatch) -> String {
        let state = match.state?.label
        let prefix = [match.query.displayText, state, match.repositoryFullName]
            .compactMap(\.self)
            .joined(separator: " ")
        let maxTitleLength = 48
        let title = match.title.count > maxTitleLength
            ? "\(match.title.prefix(maxTitleLength))…"
            : match.title
        return "\(prefix): \(title)"
    }

    private func applyStatusItemAppearance() {
        guard let button = self.statusItem?.button else { return }

        let juice = RateLimitJuice(
            diagnostics: self.appState.session.rateLimitDiagnostics,
            cacheSummary: self.appState.session.rateLimitCacheSummary
        )
        guard self.appState.session.settings.appearance.showRateLimitMeterInMenuBar,
              juice.hasData,
              let text = juice.compactRestText
        else {
            self.setButtonImage(self.fallbackStatusImage(), for: button)
            self.setButtonTitle(nil, for: button)
            button.toolTip = "RepoBar"
            button.imageScaling = .scaleProportionallyDown
            return
        }

        let image = RateLimitStatusIconRenderer.makeIcon(
            restPercent: juice.displayRestPercent,
            graphQLPercent: juice.displayGraphQLPercent
        )
        self.setButtonImage(image, for: button)
        self.setButtonTitle(text, for: button)
        button.toolTip = self.rateLimitTooltip(juice: juice)
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        button.imageScaling = .scaleNone
    }

    private func fallbackStatusImage() -> NSImage {
        let symbolName = self.appState.session.account.isLoggedIn ? "tray.fill" : "tray"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "RepoBar")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }

    private func setButtonImage(_ image: NSImage, for button: NSStatusBarButton) {
        if button.image === image { return }
        button.image = image
    }

    private func setButtonTitle(_ title: String?, for button: NSStatusBarButton) {
        let rawValue = title ?? ""
        let value = rawValue.isEmpty || button.image == nil ? rawValue : " \(rawValue)"
        if button.title != value {
            button.title = value
        }
        let position: NSControl.ImagePosition = value.isEmpty ? .imageOnly : .imageLeft
        if button.imagePosition != position {
            button.imagePosition = position
        }
    }

    private func rateLimitTooltip(juice: RateLimitJuice) -> String {
        let rest = self.rateLimitTooltipPart(label: "REST", remaining: juice.restRemaining, limit: juice.restLimit)
        let graphQL = self.rateLimitTooltipPart(label: "GraphQL", remaining: juice.graphQLRemaining, limit: juice.graphQLLimit)
        return "RepoBar GitHub rate limits: \(rest), \(graphQL)"
    }

    private func rateLimitTooltipPart(label: String, remaining: Int?, limit: Int?) -> String {
        if let remaining, let limit {
            return "\(label) \(remaining)/\(limit)"
        }
        if let remaining {
            return "\(label) \(remaining) left"
        }
        return "\(label) unknown"
    }

    @objc func toggleIssueLabelFilter(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }

        self.recentListCoordinator.toggleIssueLabelFilter(label: label)
    }

    @objc func clearIssueLabelFilters() {
        self.recentListCoordinator.clearIssueLabelFilters()
    }

    func menuWillOpen(_ menu: NSMenu) {
        let signpost = self.signposter.beginInterval("menuWillOpen")
        defer { self.signposter.endInterval("menuWillOpen", signpost) }
        if self.prepareKeyboardIssueMenuIfNeeded(menu) { return }
        self.prepareMenuAppearance(menu)
        if self.recentListCoordinator.handleMenuWillOpen(menu) { return }
        if self.localGitMenuCoordinator.handleMenuWillOpen(menu) { return }
        if self.changelogMenuCoordinator.handleMenuWillOpen(menu) { return }
        self.prefetchChangelogIfNeeded(for: menu)
        if menu === self.mainMenu {
            self.prepareMainMenuWillOpen(menu)
        } else {
            self.prepareSubmenuWillOpen(menu)
        }
    }

    private func prepareMenuAppearance(_ menu: NSMenu) {
        if menu === self.mainMenu {
            self.logMenuEvent("menuWillOpen mainMenu items=\(menu.items.count)")
        } else {
            self.logMenuEvent("menuWillOpen submenu items=\(menu.items.count)")
        }
        if let app = NSApp {
            menu.appearance = app.effectiveAppearance
        }
    }

    private func prepareKeyboardIssueMenuIfNeeded(_ menu: NSMenu) -> Bool {
        guard menu === self.keyboardIssueMenu else { return false }

        self.logMenuEvent("menuWillOpen keyboardIssueMenu items=\(menu.items.count)")
        self.refreshKeyboardIssueMenuIfNeeded(menu)
        return true
    }

    private func prefetchChangelogIfNeeded(for menu: NSMenu) {
        guard let fullName = self.menuBuilder.repoFullName(for: menu) else { return }

        let localPath = self.appState.session.localRepoIndex.status(forFullName: fullName)?.path
        let releaseTag = self.appState.session.repositories
            .first(where: { $0.fullName == fullName })?
            .latestRelease?
            .tag
        self.changelogMenuCoordinator.prefetchChangelog(
            fullName: fullName,
            localPath: localPath,
            releaseTag: releaseTag
        )
    }

    private func prepareMainMenuWillOpen(_ menu: NSMenu) {
        self.appState.reloadRateLimitCacheSummary()
        if menu.delegate == nil {
            menu.delegate = self
        }
        let plan = self.menuBuilder.mainMenuPlan()
        self.recentListCoordinator.pruneMenus()
        self.localGitMenuCoordinator.pruneMenus()
        self.changelogMenuCoordinator.pruneMenus()
        if self.appState.session.settings.appearance.showContributionHeader {
            if case let .loggedIn(user) = self.appState.session.account {
                Task { await self.appState.loadContributionHeatmapIfNeeded(for: user.username) }
            }
        }
        self.appState.refreshIfNeededForMenu()
        let isMenuTooSmall = menu.items.count < Self.minimumMainMenuItems
        if isMenuTooSmall {
            self.logMenuEvent("menuWillOpen mainMenu invalidating cache: items=\(menu.items.count)")
            self.lastMainMenuSignature = nil
        }
        let planDidRebuild = self.rebuildMainMenuIfNeeded(menu, plan: plan, isMenuTooSmall: isMenuTooSmall)
        let repoFullNames = Set(menu.items.compactMap { $0.representedObject as? String }.filter { $0.contains("/") })
        self.recentListCoordinator.prefetchRecentLists(fullNames: repoFullNames)
        self.refreshMainMenuMetricsAfterOpen(menu, plan: plan, didRebuildMenu: planDidRebuild)
    }

    private func rebuildMainMenuIfNeeded(_ menu: NSMenu, plan: MainMenuPlan, isMenuTooSmall: Bool) -> Bool {
        var didRebuildMenu = false
        if self.lastMainMenuSignature != plan.signature || menu.items.isEmpty || isMenuTooSmall {
            self.menuBuilder.populateMainMenu(menu, repos: plan.repos)
            self.lastMainMenuSignature = plan.signature
            didRebuildMenu = true
        }
        if didRebuildMenu {
            if let cachedWidth = self.lastMainMenuWidth {
                self.menuBuilder.refreshMenuViewHeights(in: menu, width: cachedWidth)
            } else {
                self.menuBuilder.refreshMenuViewHeights(in: menu)
            }
        }
        return didRebuildMenu
    }

    private func refreshMainMenuMetricsAfterOpen(_ menu: NSMenu, plan: MainMenuPlan, didRebuildMenu: Bool) {
        let shouldRecomputeWidth = self.lastMainMenuWidth == nil || self.lastMainMenuWidthSignature != plan.signature
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if shouldRecomputeWidth {
                let measuredWidth = self.menuBuilder.menuWidth(for: menu)
                let priorWidth = self.lastMainMenuWidth
                let shouldRemeasure = priorWidth == nil || abs(measuredWidth - (priorWidth ?? 0)) > 0.5
                self.lastMainMenuWidth = measuredWidth
                self.lastMainMenuWidthSignature = plan.signature
                if shouldRemeasure, didRebuildMenu {
                    self.menuBuilder.refreshMenuViewHeights(in: menu, width: measuredWidth)
                }
            }
            self.menuBuilder.clearHighlights(in: menu)
            self.startObservingMenuResize(for: menu)
        }
    }

    private func prepareSubmenuWillOpen(_ menu: NSMenu) {
        self.menuBuilder.refreshMenuViewHeights(in: menu)
        let submenuFullName = menu.supermenu?.items.first(where: { $0.submenu === menu })?.representedObject as? String
        if let fullName = submenuFullName, fullName.contains("/") {
            // Repo submenu opened; prefetch so nested recent lists appear instantly.
            self.recentListCoordinator.prefetchRecentLists(fullNames: [fullName])
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.mainMenu {
            let shouldReopen = self.pendingMenuReopen
            self.pendingMenuReopen = false
            self.menuBuilder.clearHighlights(in: menu)
            self.stopObservingMenuResize()
            self.logMenuEvent("menuDidClose mainMenu")
            if shouldReopen {
                self.reopenMainMenu()
            }
        }
    }

    private func reopenMainMenu() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            self.statusItem?.button?.performClick(nil)
        }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items {
            guard let view = menuItem.view as? MenuItemHighlighting else { continue }

            let highlighted = menuItem == item && menuItem.isEnabled
            view.setHighlighted(highlighted)
        }
    }

    func registerLocalBranchMenu(_ menu: NSMenu, repoPath: URL, fullName: String, localStatus: LocalRepoStatus) {
        self.localGitMenuCoordinator.registerLocalBranchMenu(menu, repoPath: repoPath, fullName: fullName, localStatus: localStatus)
    }

    func registerCombinedBranchMenu(_ menu: NSMenu, repoPath: URL, fullName: String, localStatus: LocalRepoStatus) {
        self.localGitMenuCoordinator.registerCombinedBranchMenu(menu, repoPath: repoPath, fullName: fullName, localStatus: localStatus)
    }

    func registerLocalWorktreeMenu(_ menu: NSMenu, repoPath: URL, fullName: String) {
        self.localGitMenuCoordinator.registerLocalWorktreeMenu(menu, repoPath: repoPath, fullName: fullName)
    }

    func registerChangelogMenu(_ menu: NSMenu, fullName: String, localStatus: LocalRepoStatus?) {
        self.changelogMenuCoordinator.registerChangelogMenu(menu, fullName: fullName, localStatus: localStatus)
    }

    func cachedChangelogPresentation(fullName: String, releaseTag: String?) -> ChangelogRowPresentation? {
        self.changelogMenuCoordinator.cachedPresentation(fullName: fullName, releaseTag: releaseTag)
    }

    func cachedChangelogHeadline(fullName: String) -> String? {
        self.changelogMenuCoordinator.cachedHeadline(fullName: fullName)
    }

    func cloneURL(for fullName: String) -> URL? {
        let host = self.appState.session.settings.githubHost
        var url = host.appendingPathComponent(fullName)
        url.appendPathExtension("git")
        return url
    }

    func showCheckoutProgress(fullName: String, destination: URL) {
        self.closeCheckoutProgress()
        let alert = NSAlert()
        alert.messageText = "Checking out \(fullName)"
        alert.informativeText = PathFormatter.displayString(destination.path)

        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.startAnimation(nil)

        let stack = NSStackView(views: [indicator])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        alert.accessoryView = stack

        let window = alert.window
        window.level = .floating
        self.checkoutProgressWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeCheckoutProgress() {
        self.checkoutProgressWindow?.close()
        self.checkoutProgressWindow = nil
    }

    func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func startObservingMenuResize(for menu: NSMenu) {
        self.stopObservingMenuResize()
        guard let window = menu.items.compactMap(\.view).first?.window else { return }

        self.menuResizeWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.menuWindowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    private func stopObservingMenuResize() {
        guard let window = self.menuResizeWindow else { return }

        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: window)
        self.menuResizeWindow = nil
    }

    @objc private func menuWindowDidResize(_: Notification) {
        guard let menu = self.mainMenu else { return }

        let width = self.menuBuilder.menuWidth(for: menu)
        self.lastMainMenuWidth = width
        self.menuBuilder.refreshMenuViewHeights(in: menu, width: width)
        menu.update()
    }

    private func logMenuEvent(_ message: String) {
        self.logger.info("\(message)")
        Task { await DiagnosticsLogger.shared.message(message) }
    }

    private func prepareMainMenuIfNeeded(_ menu: NSMenu) {
        let isMenuTooSmall = menu.items.count < Self.minimumMainMenuItems
        if self.lastMainMenuSignature == nil || menu.items.isEmpty || isMenuTooSmall {
            self.appState.reloadRateLimitCacheSummary()
            let plan = self.menuBuilder.mainMenuPlan()
            self.menuBuilder.populateMainMenu(menu, repos: plan.repos)
            self.lastMainMenuSignature = plan.signature
            self.menuBuilder.refreshMenuViewHeights(in: menu)
            menu.update()
        }
    }

    private func objectID(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }

        return String(ObjectIdentifier(object).hashValue)
    }

    func registerRecentListMenu(_ menu: NSMenu, context: RepoRecentMenuContext) {
        self.recentListCoordinator.registerRecentListMenu(menu, context: context)
    }

    func cachedRecentCommitCount(fullName: String) -> Int? {
        self.recentListCoordinator.cachedRecentCommitCount(fullName: fullName)
    }

    func repoModel(from sender: NSMenuItem) -> RepositoryDisplayModel? {
        guard let fullName = self.repoFullName(from: sender) else { return nil }
        guard let repo = self.appState.session.repositories.first(where: { $0.fullName == fullName }) else { return nil }

        let local = self.appState.session.localRepoIndex.status(forFullName: fullName)
        return RepositoryDisplayModel(repo: repo, localStatus: local)
    }

    func repoFullName(from sender: NSMenuItem) -> String? {
        sender.representedObject as? String
    }

    func openRepoPath(sender: NSMenuItem, path: String) {
        guard let fullName = self.repoFullName(from: sender),
              let url = self.webURLBuilder.repoPathURL(fullName: fullName, path: path) else { return }

        self.open(url: url)
    }

    func open(url: URL) {
        SecurityScopedBookmark.withAccess(
            to: url,
            rootBookmarkData: self.appState.session.settings.localProjects.rootBookmarkData
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openKeyboardIssueMatch(_ sender: Any?) {
        let representedURL = (sender as? NSMenuItem)?.representedObject as? URL
        guard let url = representedURL ?? self.appState.session.keyboardIssueMatch?.url else {
            self.logMenuEvent("keyboard reference click ignored: no URL")
            return
        }

        self.logMenuEvent("keyboard reference click open url=\(url.absoluteString)")
        self.open(url: url)
    }

    @objc func copyKeyboardIssueURL(_ sender: Any?) {
        let representedURL = (sender as? NSMenuItem)?.representedObject as? URL
        guard let url = representedURL ?? self.appState.session.keyboardIssueMatch?.url else {
            self.logMenuEvent("keyboard reference copy ignored: no URL")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        self.logMenuEvent("keyboard reference copied url=\(url.absoluteString)")
    }

    @objc func menuItemNoOp(_: NSMenuItem) {}

    #if DEBUG
        func setMainMenuForTesting(_ menu: NSMenu) {
            self.mainMenu = menu
        }

        func makeLocalWorktreeMenuItemForTesting(
            _ model: LocalRefMenuRowViewModel,
            path: URL,
            fullName: String
        ) -> NSMenuItem {
            self.localGitMenuCoordinator.makeLocalWorktreeMenuItemForTesting(model, path: path, fullName: fullName)
        }

        func isWorktreeMenuItemForTesting(_ item: NSMenuItem) -> Bool {
            self.localGitMenuCoordinator.isWorktreeMenuItemForTesting(item)
        }

        func isRecentListMenu(_ menu: NSMenu) -> Bool {
            self.recentListCoordinator.containsMenuForTesting(menu)
        }

        func syncKeyboardIssueStatusItemForTesting() {
            self.syncKeyboardIssueStatusItem()
        }

        func keyboardIssueStatusItemForTesting() -> NSStatusItem? {
            self.keyboardIssueStatusItem
        }

        func keyboardIssueMenuForTesting() -> NSMenu? {
            self.keyboardIssueMenu
        }
    #endif
}
