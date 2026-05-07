import AppKit
@testable import RepoBar
@testable import RepoBarCore
import Testing

@MainActor
struct KeyboardIssueMonitorTests {
    @Test
    func `bare numbers and issue prefixes become issue queries`() {
        #expect(KeyboardIssueMonitor.query(from: "73655") == .issueNumber(73655))
        #expect(KeyboardIssueMonitor.query(from: "7") == .issueNumber(7))
        #expect(KeyboardIssueMonitor.query(from: "#7") == .issueNumber(7))
        #expect(KeyboardIssueMonitor.query(from: "gh-42") == .issueNumber(42))
        #expect(KeyboardIssueMonitor.query(from: "a73655") == nil)
    }

    @Test
    func `commit hashes become commit queries`() {
        #expect(KeyboardIssueMonitor.query(from: "ffd212ca43") == .commitHash("ffd212ca43"))
        #expect(KeyboardIssueMonitor.query(from: "1234567") == .issueNumber(1_234_567))
        #expect(KeyboardIssueMonitor.query(from: "abcdef") == nil)
    }

    @Test
    func `github issue and pr urls become repository scoped issue queries`() {
        #expect(
            KeyboardIssueMonitor.query(from: "https://github.com/openclaw/openclaw/issues/73655") ==
                .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw", number: 73655)
        )
        #expect(
            KeyboardIssueMonitor.query(from: "https://github.com/openclaw/openclaw/pull/123") ==
                .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw", number: 123)
        )
    }

    @Test
    func `github commit urls become repository scoped commit queries`() {
        #expect(
            KeyboardIssueMonitor.query(from: "https://github.com/openclaw/openclaw/commit/ffd212ca43abcdef") ==
                .repositoryCommitHash(repositoryFullName: "openclaw/openclaw", hash: "ffd212ca43abcdef")
        )
        #expect(
            KeyboardIssueMonitor.query(from: "https://github.com/openclaw/openclaw/commits/ffd212ca43") ==
                .repositoryCommitHash(repositoryFullName: "openclaw/openclaw", hash: "ffd212ca43")
        )
    }

    @Test
    func `pasteboard polling reports copied github references`() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("RepoBarTests.\(UUID().uuidString)"))
        pasteboard.clearContents()

        let stream = AsyncStream<GitHubReferenceQuery> { continuation in
            let monitor = KeyboardIssueMonitor(pasteboard: pasteboard) { query in
                continuation.yield(query)
            }
            continuation.onTermination = { _ in
                Task { @MainActor in monitor.stop() }
            }
            monitor.start(includeKeyboardEvents: false)
        }

        pasteboard.clearContents()
        pasteboard.setString("https://github.com/openclaw/openclaw/issues/76162", forType: .string)

        let query = try await self.nextQuery(from: stream)
        #expect(query == .repositoryIssueNumber(repositoryFullName: "openclaw/openclaw", number: 76162))
        pasteboard.clearContents()
    }

    @Test
    func `pasteboard polling clears copied non references`() async throws {
        enum Event: Equatable, Sendable {
            case clear
            case query(GitHubReferenceQuery)
        }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("RepoBarTests.\(UUID().uuidString)"))
        pasteboard.clearContents()

        let stream = AsyncStream<Event> { continuation in
            let monitor = KeyboardIssueMonitor(
                pasteboard: pasteboard,
                onPasteboardWithoutReference: {
                    continuation.yield(.clear)
                },
                onReference: { query in
                    continuation.yield(.query(query))
                }
            )
            continuation.onTermination = { _ in
                Task { @MainActor in monitor.stop() }
            }
            monitor.start(includeKeyboardEvents: false)
        }

        pasteboard.clearContents()
        pasteboard.setString("https://github.com/openclaw/openclaw/issues/76162", forType: .string)
        #expect(
            try await self.nextValue(from: stream) ==
                .query(.repositoryIssueNumber(repositoryFullName: "openclaw/openclaw", number: 76162))
        )

        pasteboard.clearContents()
        pasteboard.setString("no github reference here", forType: .string)
        #expect(try await self.nextValue(from: stream) == .clear)
        pasteboard.clearContents()
    }

    private func nextQuery(from stream: AsyncStream<GitHubReferenceQuery>) async throws -> GitHubReferenceQuery {
        try await self.nextValue(from: stream)
    }

    private func nextValue<Value: Sendable>(from stream: AsyncStream<Value>) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                for await value in stream {
                    return value
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw CancellationError()
            }
            let value = try await #require(group.next())
            group.cancelAll()
            return value
        }
    }
}
