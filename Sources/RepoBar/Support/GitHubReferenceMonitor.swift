import AppKit
import RepoBarCore

@MainActor
final class GitHubReferenceMonitor {
    private let minimumBareDigits: Int
    private let pasteboard: NSPasteboard
    private let onPasteboardWithoutReference: () async -> Void
    private let onReference: (GitHubReferenceQuery) async -> Void
    private var pasteboardPoller: PasteboardTextPoller?
    private var isRunning = false

    init(
        minimumBareDigits: Int = AppLimits.GitHubReferenceMonitor.minimumBareDigits,
        pasteboard: NSPasteboard = .general,
        onPasteboardWithoutReference: @escaping () async -> Void = {},
        onReference: @escaping (GitHubReferenceQuery) async -> Void
    ) {
        self.minimumBareDigits = minimumBareDigits
        self.pasteboard = pasteboard
        self.onPasteboardWithoutReference = onPasteboardWithoutReference
        self.onReference = onReference
    }

    func start() {
        guard self.isRunning == false else { return }

        if self.pasteboardPoller == nil {
            self.startPasteboardTimer()
        }
        self.isRunning = true
    }

    func stop() {
        self.pasteboardPoller?.stop()
        self.pasteboardPoller = nil
        self.isRunning = false
    }

    private func startPasteboardTimer() {
        let poller = PasteboardTextPoller(pasteboard: self.pasteboard) { [weak self] text in
            Task { @MainActor in
                self?.handlePasteboardText(text)
            }
        }
        poller.start()
        self.pasteboardPoller = poller
    }

    private func handlePasteboardText(_ text: String) {
        guard let query = Self.query(from: text, minimumBareDigits: self.minimumBareDigits) else {
            Task { await self.onPasteboardWithoutReference() }
            return
        }

        Task { await self.onReference(query) }
    }

    static func query(from rawText: String, minimumBareDigits: Int = AppLimits.GitHubReferenceMonitor.minimumBareDigits) -> GitHubReferenceQuery? {
        if let query = self.urlQuery(from: rawText) {
            return query
        }

        return self.tokenQuery(from: rawText, minimumBareDigits: minimumBareDigits)
    }

    private static func tokenQuery(from rawToken: String, minimumBareDigits: Int) -> GitHubReferenceQuery? {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard token.isEmpty == false else { return nil }

        if let number = self.issueNumber(from: token, minimumBareDigits: minimumBareDigits) {
            return .issueNumber(number)
        }
        if self.isCommitHash(token) {
            return .commitHash(token)
        }
        return nil
    }

    private static func urlQuery(from rawText: String) -> GitHubReferenceQuery? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased().hasPrefix("http") == true
        else { return nil }

        let host = components.host?.lowercased() ?? ""
        guard host == "github.com" || host.hasSuffix(".github.com") else { return nil }

        let pathParts = components.path
            .split(separator: "/")
            .map(String.init)
        guard pathParts.count >= 4 else { return nil }

        let repositoryFullName = "\(pathParts[0])/\(pathParts[1])"
        if let hash = self.commitHash(in: pathParts.dropFirst(2)) {
            return .repositoryCommitHash(repositoryFullName: repositoryFullName, hash: hash)
        }

        switch pathParts[2].lowercased() {
        case "issues", "pull":
            guard let number = Int(pathParts[3]) else { return nil }

            return .repositoryIssueNumber(repositoryFullName: repositoryFullName, number: number)
        case "commit", "commits":
            let hash = pathParts[3].lowercased()
            guard self.isCommitHash(hash) else { return nil }

            return .repositoryCommitHash(repositoryFullName: repositoryFullName, hash: hash)
        default:
            return nil
        }
    }

    private static func commitHash<S: Sequence>(in pathParts: S) -> String? where S.Element == String {
        pathParts
            .map { $0.lowercased() }
            .first(where: self.isCommitHash)
    }

    private static func issueNumber(from token: String, minimumBareDigits: Int) -> Int? {
        if token.hasPrefix("#") {
            return Int(token.dropFirst())
        }
        if token.hasPrefix("gh-") {
            return Int(token.dropFirst(3))
        }
        guard token.count >= minimumBareDigits,
              token.allSatisfy(\.isNumber)
        else { return nil }

        return Int(token)
    }

    private static func isCommitHash(_ token: String) -> Bool {
        guard (7 ... 40).contains(token.count) else { return false }
        guard token.allSatisfy(\.isHexDigit) else { return false }

        return token.contains { ("a" ... "f").contains($0) }
    }

}

private final class PasteboardTextPoller: @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let queue = DispatchQueue(label: "com.steipete.repobar.github-reference-pasteboard", qos: .utility)
    private let onText: @Sendable (String) -> Void
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int
    private let pollInterval: DispatchTimeInterval = .seconds(2)
    private let pollLeeway: DispatchTimeInterval = .milliseconds(500)
    private let graceDelay: DispatchTimeInterval = .milliseconds(100)

    init(pasteboard: NSPasteboard, onText: @escaping @Sendable (String) -> Void) {
        self.pasteboard = pasteboard
        self.onText = onText
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        self.queue.async { [weak self] in
            guard let self, self.timer == nil else { return }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval, leeway: self.pollLeeway)
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        self.queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func tick() {
        let changeCount = self.pasteboard.changeCount
        guard changeCount != self.lastChangeCount else { return }

        self.lastChangeCount = changeCount
        self.queue.asyncAfter(deadline: .now() + self.graceDelay) { [weak self] in
            guard let self else { return }
            guard changeCount == self.pasteboard.changeCount else { return }
            guard let text = self.readPasteboardText() else { return }

            self.onText(text)
        }
    }

    private func readPasteboardText() -> String? {
        if let direct = self.pasteboard.string(forType: .string) {
            return direct
        }

        let preferredTypes: [NSPasteboard.PasteboardType] = [
            .init("public.utf8-plain-text"),
            .init("public.utf16-external-plain-text"),
            .init("public.text")
        ]
        for item in self.pasteboard.pasteboardItems ?? [] {
            for type in preferredTypes {
                if let value = item.string(forType: type) {
                    return value
                }
            }
        }
        return nil
    }
}
