import AppKit
import RepoBarCore

@MainActor
final class KeyboardIssueMonitor {
    private let minimumBareDigits: Int
    private let maximumTokenLength: Int
    private let resetDelay: TimeInterval
    private let pasteboard: NSPasteboard
    private let onPasteboardWithoutReference: () async -> Void
    private let onReference: (GitHubReferenceQuery) async -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pasteboardPoller: PasteboardTextPoller?
    private var token = ""
    private var resetTask: Task<Void, Never>?
    private var includeKeyboardEvents = false
    private var isRunning = false

    init(
        minimumBareDigits: Int = AppLimits.IssueNumberMonitor.minimumBareDigits,
        maximumTokenLength: Int = AppLimits.IssueNumberMonitor.maximumTokenLength,
        resetDelay: TimeInterval = AppLimits.IssueNumberMonitor.resetDelay,
        pasteboard: NSPasteboard = .general,
        onPasteboardWithoutReference: @escaping () async -> Void = {},
        onReference: @escaping (GitHubReferenceQuery) async -> Void
    ) {
        self.minimumBareDigits = minimumBareDigits
        self.maximumTokenLength = maximumTokenLength
        self.resetDelay = resetDelay
        self.pasteboard = pasteboard
        self.onPasteboardWithoutReference = onPasteboardWithoutReference
        self.onReference = onReference
    }

    func start(includeKeyboardEvents: Bool) {
        guard self.isRunning == false || self.includeKeyboardEvents != includeKeyboardEvents else { return }

        self.includeKeyboardEvents = includeKeyboardEvents
        if includeKeyboardEvents {
            self.startKeyboardMonitors()
        } else {
            self.stopKeyboardMonitors()
        }
        if self.pasteboardPoller == nil {
            self.startPasteboardTimer()
        }
        self.isRunning = true
    }

    func stop() {
        self.stopKeyboardMonitors()
        self.pasteboardPoller?.stop()
        self.pasteboardPoller = nil
        self.resetTask?.cancel()
        self.resetTask = nil
        self.token = ""
        self.includeKeyboardEvents = false
        self.isRunning = false
    }

    private func startKeyboardMonitors() {
        if self.globalMonitor == nil {
            self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
        }
        if self.localMonitor == nil {
            self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event)
                return event
            }
        }
    }

    private func stopKeyboardMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        self.globalMonitor = nil
        self.localMonitor = nil
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

    private func handle(_ event: NSEvent) {
        guard self.shouldAccept(event: event) else {
            self.flushToken()
            return
        }
        guard let character = event.charactersIgnoringModifiers?.first else {
            self.flushToken()
            return
        }
        guard self.isTokenCharacter(character) else {
            self.flushToken()
            return
        }

        self.token.append(Character(character.lowercased()))
        if self.token.count > self.maximumTokenLength {
            self.token = String(self.token.suffix(self.maximumTokenLength))
        }
        self.resetSoon()
    }

    private func shouldAccept(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let disallowed: NSEvent.ModifierFlags = [.command, .control, .option]
        return flags.isDisjoint(with: disallowed)
    }

    private func resetSoon() {
        self.resetTask?.cancel()
        self.resetTask = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: .seconds(self.resetDelay))
            if !Task.isCancelled {
                self.flushToken()
            }
        }
    }

    private func flushToken() {
        self.resetTask?.cancel()
        self.resetTask = nil
        let token = self.token
        self.token = ""
        guard let query = Self.query(from: token, minimumBareDigits: self.minimumBareDigits) else { return }

        Task { await self.onReference(query) }
    }

    static func query(from rawText: String, minimumBareDigits: Int = AppLimits.IssueNumberMonitor.minimumBareDigits) -> GitHubReferenceQuery? {
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

    private func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "#" || character == "-"
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
