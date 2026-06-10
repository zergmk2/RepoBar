import Foundation
@testable import RepoBarCore
import Testing

struct GitHubRequestRunnerTests {
    @Test
    func `etag requests bypass URLSession local cache`() throws {
        let url = try #require(URL(string: "https://api.github.com/repos/owner/repo/releases"))

        let request = GitHubRequestRunner.makeRequest(url: url, token: "token", useETag: true)
        let uncachedRequest = GitHubRequestRunner.makeRequest(url: url, token: "token", useETag: false)

        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(uncachedRequest.cachePolicy == .useProtocolCachePolicy)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test
    func `etag body cache stores only successful responses`() {
        #expect(GitHubRequestRunner.shouldCacheETagResponse(statusCode: 200))
        #expect(GitHubRequestRunner.shouldCacheETagResponse(statusCode: 304) == false)
        #expect(GitHubRequestRunner.shouldCacheETagResponse(statusCode: 404) == false)
    }

    @Test
    func `cooldown message names endpoint`() async throws {
        let url = try #require(URL(string: "https://api.github.com/repos/owner/repo/stats/commit_activity"))
        let backoff = BackoffTracker()
        let retryAfter = Date().addingTimeInterval(30)
        await backoff.setCooldown(url: url, until: retryAfter)
        let runner = GitHubRequestRunner(etagCache: ETagCache(), backoff: backoff)

        do {
            _ = try await runner.get(url: url, token: "token")
            Issue.record("Expected cooldown error")
        } catch let error as GitHubAPIError {
            #expect(error.displayMessage.hasPrefix("GitHub endpoint cooldown (commit activity); retry in "))
            #expect(error.displayMessage.contains("until in") == false)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `cooldown message identifies actions endpoint`() throws {
        let url = try #require(URL(string: "https://api.github.com/repos/owner/repo/actions/runs?per_page=20"))
        let retryAfter = Date(timeIntervalSinceReferenceDate: 60)
        let now = Date(timeIntervalSinceReferenceDate: 30)

        let message = GitHubRequestRunner.cooldownMessage(for: url, until: retryAfter, now: now)

        #expect(message == "GitHub endpoint cooldown (Actions runs); retry in 30 sec.")
    }

    @Test
    func `bad status message includes GitHub response detail`() {
        let data = Data("""
        {
          "message": "Validation Failed",
          "errors": [
            { "resource": "Search", "field": "q", "code": "invalid", "message": "Search query is too broad." }
          ]
        }
        """.utf8)

        let message = GitHubRequestRunner.statusMessage(for: 422, data: data)

        #expect(message == "GitHub returned 422: Validation Failed: Search query is too broad.")
    }

    @Test
    func `bad status message keeps fallback for non github body`() {
        let data = Data("nope".utf8)

        let message = GitHubRequestRunner.statusMessage(for: 422, data: data)

        #expect(message == "GitHub returned 422: client error.")
    }

    @Test
    func `diagnostics expose endpoint cooldowns`() async throws {
        let url = try #require(URL(string: "https://api.github.com/repos/owner/repo/stats/commit_activity"))
        let backoff = BackoffTracker()
        let retryAfter = Date().addingTimeInterval(30)
        await backoff.setCooldown(url: url, until: retryAfter)
        let runner = GitHubRequestRunner(backoff: backoff)

        let diagnostics = await runner.diagnosticsSnapshot()

        #expect(diagnostics.backoffEntries == 1)
        #expect(diagnostics.endpointCooldowns.count == 1)
        #expect(diagnostics.endpointCooldowns.first?.endpoint == "commit activity")
        #expect(diagnostics.endpointCooldowns.first?.repository == "owner/repo")
    }

    @Test
    func `log path redacts query values`() throws {
        let url = try #require(URL(string: "https://api.github.com/search/issues?q=repo:owner/private+secret&per_page=50"))

        let path = GitHubRequestRunner.logPath(for: url)

        #expect(path == "/search/issues?q=<redacted>&per_page=<redacted>")
        #expect(path.contains("owner/private") == false)
        #expect(path.contains("secret") == false)
    }
}
