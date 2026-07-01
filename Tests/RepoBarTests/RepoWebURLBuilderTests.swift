import Foundation
@testable import RepoBar
import Testing

struct RepoWebURLBuilderTests {
    @Test
    func `repo URL uses configured GitHub host`() throws {
        let host = try #require(URL(string: "https://github.example.com"))
        let builder = RepoWebURLBuilder(host: host)

        #expect(builder.repoURL(fullName: "acme/widget")?.absoluteString == "https://github.example.com/acme/widget")
    }

    @Test
    func `repo URL supports GitLab subgroup paths`() throws {
        let host = try #require(URL(string: "https://gitlab.example.com:1180"))
        let builder = RepoWebURLBuilder(host: host, provider: .gitlab)

        #expect(
            builder.repoURL(fullName: "platform/backend/widget")?.absoluteString ==
                "https://gitlab.example.com:1180/platform/backend/widget"
        )
    }

    @Test
    func `GitLab URLs use provider routes`() throws {
        let host = try #require(URL(string: "https://gitlab.example.com"))
        let builder = RepoWebURLBuilder(host: host, provider: .gitlab)
        let repo = "platform/backend/widget"

        #expect(builder.issuesURL(fullName: repo)?.absoluteString == "https://gitlab.example.com/platform/backend/widget/-/issues")
        #expect(builder.pullsURL(fullName: repo)?.absoluteString == "https://gitlab.example.com/platform/backend/widget/-/merge_requests")
        #expect(builder.tagsURL(fullName: repo)?.absoluteString == "https://gitlab.example.com/platform/backend/widget/-/tags")
        #expect(builder.branchesURL(fullName: repo)?.absoluteString == "https://gitlab.example.com/platform/backend/widget/-/branches")
        #expect(builder.commitsURL(fullName: repo)?.absoluteString == "https://gitlab.example.com/platform/backend/widget/-/commits")
        #expect(builder.releasesURL(fullName: repo)?.absoluteString == "https://gitlab.example.com/platform/backend/widget/-/releases")
        #expect(builder.branchURL(fullName: repo, branch: "feature/test")?.absoluteString == "https://gitlab.example.com/platform/backend/widget/-/tree/feature/test")
        #expect(builder.discussionsURL(fullName: repo) == nil)
    }

    @Test
    func `GitLab CI URL uses pipelines path`() throws {
        let host = try #require(URL(string: "https://gitlab.example.com"))
        let builder = RepoWebURLBuilder(host: host, provider: .gitlab)

        #expect(
            builder.ciRunsURL(fullName: "platform/backend/widget")?.absoluteString ==
                "https://gitlab.example.com/platform/backend/widget/-/pipelines"
        )
    }

    @Test
    func `repo URL rejects malformed repository names`() throws {
        let host = try #require(URL(string: "https://github.com"))
        let builder = RepoWebURLBuilder(host: host)

        #expect(builder.repoURL(fullName: "widget") == nil)
        #expect(builder.repoURL(fullName: "acme/widget/extra") == nil)
        #expect(builder.repoURL(fullName: "acme//widget") == nil)
    }
}
