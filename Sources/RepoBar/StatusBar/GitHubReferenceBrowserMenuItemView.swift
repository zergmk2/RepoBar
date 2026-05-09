import AppKit
import RepoBarCore
import WebKit

@MainActor
final class GitHubReferenceBrowserMenuItemView: NSView {
    private enum Metrics {
        static let width: CGFloat = 740
        static let height: CGFloat = 680
    }

    private let url: URL
    private let webView: WKWebView
    private var hasLoaded = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.width, height: Metrics.height)
    }

    init(match: GitHubReferenceMatch) {
        self.url = match.url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Metrics.width, height: Metrics.height)))
        self.configureView()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard self.window != nil else { return }

        self.loadIfNeeded()
    }

    func preload() {
        self.loadIfNeeded()
    }

    private func configureView() {
        self.webView.translatesAutoresizingMaskIntoConstraints = false
        self.webView.allowsBackForwardNavigationGestures = false
        self.addSubview(self.webView)

        NSLayoutConstraint.activate([
            self.webView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.webView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.webView.topAnchor.constraint(equalTo: self.topAnchor),
            self.webView.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])
    }

    private func loadIfNeeded() {
        guard !self.hasLoaded else { return }

        self.hasLoaded = true
        self.webView.load(URLRequest(url: self.url))
    }
}
