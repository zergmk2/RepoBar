import AppKit
import RepoBarCore
import SwiftUI

// swiftlint:disable file_length

struct IssueNavigatorView: View {
    private enum Metrics {
        static let sidebarMinWidth: CGFloat = 380
        static let sidebarIdealWidth: CGFloat = 470
        static let sidebarMaxWidth: CGFloat = 560
        static let sidebarPadding: CGFloat = 14
        static let controlHeight: CGFloat = 28
        static let controlCornerRadius: CGFloat = 10
    }

    let appState: AppState
    @State private var model: IssueNavigatorModel

    init(
        appState: AppState,
        initialMatches: [GitHubReferenceMatch] = [],
        browserStore: IssueNavigatorBrowserStore
    ) {
        self.appState = appState
        self._model = State(
            initialValue: IssueNavigatorModel(
                appState: appState,
                initialMatches: initialMatches,
                browserStore: browserStore
            )
        )
    }

    var body: some View {
        IssueNavigatorSplitView(
            sidebarMinWidth: Metrics.sidebarMinWidth,
            sidebarIdealWidth: Metrics.sidebarIdealWidth,
            sidebarMaxWidth: Metrics.sidebarMaxWidth
        ) {
            self.sidebar
        } detail: {
            self.previewPane
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.ultraThinMaterial)
        .frame(minWidth: 1080, minHeight: 620)
        .onAppear {
            self.model.start(
                seedClipboard: Self.shouldSeedClipboardOnAppear(hasInitialMatches: self.model.results.isEmpty == false)
            )
        }
        .onDisappear {
            self.model.stop()
        }
        .onReceive(
            Timer.publish(every: 1, tolerance: 0.25, on: .main, in: .common).autoconnect()
        ) { _ in
            self.model.updateClipboard(seedIfEmpty: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .issueNavigatorUseClipboard)) { _ in
            self.model.useClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: .issueNavigatorRefresh)) { _ in
            self.model.scheduleSearch(immediate: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .issueNavigatorCopy)) { _ in
            self.model.copySelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .issueNavigatorOpen)) { _ in
            self.model.openSelected()
        }
        .onChange(of: self.model.searchText) { _, _ in self.model.scheduleSearch() }
        .onChange(of: self.model.kindFilter) { _, _ in self.model.scheduleSearch(immediate: true) }
        .onChange(of: self.model.selectedScope) { _, _ in self.model.scheduleSearch(immediate: true) }
        .onChange(of: self.appState.session.settings.aiSummaries) { _, settings in
            self.model.aiSummarySettingsDidChange(settings)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            self.sidebarControls
            self.resultPane
        }
        .frame(maxHeight: .infinity)
        .background(.thinMaterial)
    }

    private var sidebarControls: some View {
        @Bindable var model = self.model

        return VStack(alignment: .leading, spacing: 8) {
            IssueNavigatorSearchField(
                text: $model.searchText,
                placeholder: "Search issues and pull requests",
                onSubmit: {
                    self.model.submitSearch()
                }
            )
            .frame(height: Metrics.controlHeight)

            HStack(spacing: 8) {
                IssueNavigatorScopePopUp(selection: $model.selectedScope, scopes: self.model.scopes)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.controlHeight)

                if self.model.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            IssueNavigatorKindSegmentedControl(selection: $model.kindFilter)
                .frame(height: Metrics.controlHeight)

            if self.model.shouldShowClipboardPrompt {
                Button {
                    self.model.useClipboard()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Clipboard: \(self.model.clipboardDisplayText)")
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.turn.down.left")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 11)
                .frame(height: Metrics.controlHeight)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: Metrics.controlCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.controlCornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.22))
                )
            }

            Text(self.model.statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Metrics.sidebarPadding)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var resultPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                IssueNavigatorCountBadge(count: self.model.results.count)
                Spacer()
                Text("Updated newest first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Metrics.sidebarPadding)
            .padding(.top, 2)
            .padding(.bottom, 10)

            if let errorText = self.model.errorText {
                self.sidebarMessage(
                    title: "Search failed",
                    message: errorText,
                    systemImage: "exclamationmark.triangle"
                )
            } else if self.model.results.isEmpty {
                self.sidebarMessage(
                    title: "No matches",
                    message: self.model.statusText,
                    systemImage: "tray"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(self.model.results, id: \.url) { match in
                            IssueNavigatorResultRow(
                                match: self.model.displayMatch(match),
                                now: Date(),
                                isSelected: self.model.selectedURL == match.url,
                                onOpen: { self.model.open(match) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                self.model.select(match)
                            }
                            .contextMenu {
                                Button("Open in Browser") { self.model.open(match) }
                                Button("Copy URL") { self.model.copy(match) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 14)
                }
                .onChange(of: self.model.selectedURL) { _, _ in
                    self.model.ensureSelection()
                }
            }
        }
    }

    private func sidebarMessage(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 68)
            .padding(.bottom, 20)

            Spacer(minLength: 0)
        }
    }

    private var previewPane: some View {
        Group {
            if let match = self.model.selectedMatch {
                VStack(spacing: 0) {
                    self.previewHeader(for: match)
                    IssueNavigatorBrowserPreview(url: match.url, store: self.model.browserStore)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.and.text.magnifyingglass")
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(.tertiary)
                    Text("Pick a result")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Search by title, URL, owner/repo#number, or commit SHA.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .padding(26)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func previewHeader(for match: GitHubReferenceMatch) -> some View {
        let canGoBack = self.model.browserStore.canGoBack(match.url)

        return HStack(spacing: 12) {
            Button {
                self.model.browserStore.goBack(match.url)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(!canGoBack)
            .help("Back")

            ZStack {
                Circle()
                    .fill(self.tint(for: match).opacity(0.16))
                Image(systemName: self.symbolName(for: match))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(self.tint(for: match))
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(match.issueNavigatorHeaderTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(match.repositoryFullName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(match.query.displayText)
                    if let state = match.state?.label {
                        Text(state)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .id(self.model.browserNavigationVersion)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    nonisolated static func shouldSeedClipboardOnAppear(hasInitialMatches: Bool) -> Bool {
        !hasInitialMatches
    }

    private func symbolName(for match: GitHubReferenceMatch) -> String {
        switch match.kind {
        case .issue:
            match.state == .closed ? "checkmark.circle" : "exclamationmark.circle"
        case .pullRequest:
            switch match.state {
            case .merged: "arrow.triangle.merge"
            case .closed: "xmark.circle"
            case .open, nil: "arrow.triangle.pull"
            }
        case .commit:
            "number.square"
        case .workflowRun:
            "play.circle"
        }
    }

    private func tint(for match: GitHubReferenceMatch) -> Color {
        switch match.kind {
        case .issue:
            match.state == .closed ? .purple : .green
        case .pullRequest:
            match.state == .merged ? .purple : (match.state == .closed ? .red : .green)
        case .commit, .workflowRun:
            .secondary
        }
    }
}

private struct IssueNavigatorResultRow: View {
    let match: GitHubReferenceMatch
    let now: Date
    let isSelected: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: self.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(self.iconForeground)
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(self.match.issueNavigatorTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(self.primaryForeground)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(self.match.repositoryFullName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let state = match.state?.label {
                        Text(state)
                    }
                    Text(RelativeFormatter.string(from: self.match.updatedAt, relativeTo: self.now))
                }
                .font(.caption)
                .foregroundStyle(self.secondaryForeground)
                if let summary = self.summaryDisplayText, summary.isEmpty == false {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(self.secondaryForeground)
                        .lineLimit(self.summaryLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(self.rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(count: 2, perform: self.onOpen)
    }

    private var symbolName: String {
        switch self.match.kind {
        case .issue:
            self.match.state == .closed ? "checkmark.circle" : "exclamationmark.circle"
        case .pullRequest:
            switch self.match.state {
            case .merged: "arrow.triangle.merge"
            case .closed: "xmark.circle"
            case .open, nil: "arrow.triangle.branch.circle"
            }
        case .commit:
            "number.square"
        case .workflowRun:
            "play.circle"
        }
    }

    private var tint: Color {
        switch self.match.kind {
        case .issue:
            self.match.state == .closed ? .purple : .green
        case .pullRequest:
            self.match.state == .merged ? .purple : (self.match.state == .closed ? .red : .green)
        case .commit, .workflowRun:
            .secondary
        }
    }

    private var primaryForeground: Color {
        self.isSelected ? .white : .primary
    }

    private var secondaryForeground: Color {
        self.isSelected ? Color.white.opacity(0.76) : .secondary
    }

    private var iconForeground: Color {
        self.isSelected ? Color.white.opacity(0.92) : self.tint
    }

    private var summaryDisplayText: String? {
        self.match.aiSummary ?? self.match.bodyPreview
    }

    private var summaryLineLimit: Int {
        self.match.aiSummary == nil ? 2 : 4
    }

    private var rowBackground: Color {
        self.isSelected ? Color.accentColor.opacity(0.86) : .clear
    }
}

private struct IssueNavigatorCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            Text("\(self.count)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Text(self.count == 1 ? "match" : "matches")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
    }
}

private struct IssueNavigatorSplitView<Sidebar: View, Detail: View>: NSViewRepresentable {
    let sidebarMinWidth: CGFloat
    let sidebarIdealWidth: CGFloat
    let sidebarMaxWidth: CGFloat
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sidebarMinWidth: self.sidebarMinWidth,
            sidebarIdealWidth: self.sidebarIdealWidth,
            sidebarMaxWidth: self.sidebarMaxWidth
        )
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = IssueNavigatorNSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        let sidebarHost = NSHostingView(rootView: self.sidebar())
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        sidebarHost.wantsLayer = false
        let detailHost = NSHostingView(rootView: self.detail())
        detailHost.translatesAutoresizingMaskIntoConstraints = false
        detailHost.wantsLayer = false

        context.coordinator.sidebarHost = sidebarHost
        context.coordinator.detailHost = detailHost

        splitView.addArrangedSubview(sidebarHost)
        splitView.addArrangedSubview(detailHost)
        sidebarHost.widthAnchor.constraint(greaterThanOrEqualToConstant: self.sidebarMinWidth).isActive = true
        sidebarHost.widthAnchor.constraint(lessThanOrEqualToConstant: self.sidebarMaxWidth).isActive = true
        detailHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(230), forSubviewAt: 1)

        DispatchQueue.main.async {
            splitView.setPosition(self.sidebarIdealWidth, ofDividerAt: 0)
        }

        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.sidebarMinWidth = self.sidebarMinWidth
        context.coordinator.sidebarIdealWidth = self.sidebarIdealWidth
        context.coordinator.sidebarMaxWidth = self.sidebarMaxWidth
        context.coordinator.sidebarHost?.rootView = self.sidebar()
        context.coordinator.detailHost?.rootView = self.detail()

        if splitView.frame.width > 0, splitView.subviews.first?.frame.width == 0 {
            splitView.setPosition(self.sidebarIdealWidth, ofDividerAt: 0)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var sidebarMinWidth: CGFloat
        var sidebarIdealWidth: CGFloat
        var sidebarMaxWidth: CGFloat
        var sidebarHost: NSHostingView<Sidebar>?
        var detailHost: NSHostingView<Detail>?

        init(sidebarMinWidth: CGFloat, sidebarIdealWidth: CGFloat, sidebarMaxWidth: CGFloat) {
            self.sidebarMinWidth = sidebarMinWidth
            self.sidebarIdealWidth = sidebarIdealWidth
            self.sidebarMaxWidth = sidebarMaxWidth
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainSplitPosition proposedPosition: CGFloat,
            ofSubviewAt _: Int
        ) -> CGFloat {
            let maximum = min(self.sidebarMaxWidth, splitView.bounds.width - 560 - splitView.dividerThickness)
            return min(max(proposedPosition, self.sidebarMinWidth), maximum)
        }
    }
}

private final class IssueNavigatorNSSplitView: NSSplitView {
    override var dividerThickness: CGFloat {
        1
    }

    override func drawDivider(in rect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        rect.fill()
    }
}

private struct IssueNavigatorSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: self.$text, onSubmit: self.onSubmit)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = self.placeholder
        field.controlSize = .regular
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .regular)
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = self.$text
        context.coordinator.onSubmit = self.onSubmit
        if field.stringValue != self.text {
            field.stringValue = self.text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }

            self.text.wrappedValue = field.stringValue
        }

        func control(
            _: NSControl,
            textView _: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }

            self.onSubmit()
            return true
        }
    }
}

private struct IssueNavigatorScopePopUp: NSViewRepresentable {
    @Binding var selection: IssueNavigatorScope
    let scopes: [IssueNavigatorScope]

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: self.$selection, scopes: self.scopes)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .regular
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.select(_:))
        context.coordinator.configure(popup)
        return popup
    }

    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        context.coordinator.selection = self.$selection
        context.coordinator.scopes = self.scopes
        context.coordinator.configure(popup)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<IssueNavigatorScope>
        var scopes: [IssueNavigatorScope]

        init(selection: Binding<IssueNavigatorScope>, scopes: [IssueNavigatorScope]) {
            self.selection = selection
            self.scopes = scopes
        }

        func configure(_ popup: NSPopUpButton) {
            let representedIDs = popup.itemArray.compactMap { $0.representedObject as? String }
            let scopeIDs = self.scopes.map(\.id)
            if representedIDs != scopeIDs {
                popup.removeAllItems()
                for scope in self.scopes {
                    popup.addItem(withTitle: scope.title)
                    popup.lastItem?.representedObject = scope.id
                }
            }
            if let index = self.scopes.firstIndex(of: self.selection.wrappedValue) {
                popup.selectItem(at: index)
            }
        }

        @objc func select(_ popup: NSPopUpButton) {
            let index = popup.indexOfSelectedItem
            guard self.scopes.indices.contains(index) else { return }

            self.selection.wrappedValue = self.scopes[index]
        }
    }
}

private struct IssueNavigatorKindSegmentedControl: NSViewRepresentable {
    @Binding var selection: IssueNavigatorKindFilter

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: self.$selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: IssueNavigatorKindFilter.allCases.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.select(_:))
        )
        control.controlSize = .regular
        control.segmentStyle = .rounded
        context.coordinator.configure(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = self.$selection
        context.coordinator.configure(control)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<IssueNavigatorKindFilter>

        init(selection: Binding<IssueNavigatorKindFilter>) {
            self.selection = selection
        }

        func configure(_ control: NSSegmentedControl) {
            let cases = IssueNavigatorKindFilter.allCases
            control.segmentCount = cases.count
            for (index, filter) in cases.enumerated() {
                control.setLabel(filter.title, forSegment: index)
                control.setWidth(0, forSegment: index)
            }
            control.selectedSegment = cases.firstIndex(of: self.selection.wrappedValue) ?? 0
        }

        @objc func select(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            let cases = IssueNavigatorKindFilter.allCases
            guard cases.indices.contains(index) else { return }

            self.selection.wrappedValue = cases[index]
        }
    }
}

private struct IssueNavigatorBrowserPreview: NSViewRepresentable {
    let url: URL
    let store: IssueNavigatorBrowserStore

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        let webView = self.store.webView(for: self.url)
        guard webView.superview !== container else {
            webView.frame = container.bounds
            return
        }

        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    static func dismantleNSView(_ container: NSView, coordinator _: ()) {
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
    }
}
