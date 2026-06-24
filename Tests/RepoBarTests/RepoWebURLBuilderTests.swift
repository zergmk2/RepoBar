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
        let host = try #require(URL(string: "http://gitlab.example.com:1180"))
        let builder = RepoWebURLBuilder(host: host, provider: .gitlab)

        #expect(
            builder.repoURL(fullName: "platform/backend/widget")?.absoluteString ==
                "http://gitlab.example.com:1180/platform/backend/widget"
        )
    }

    @Test
    func `GitLab jobs URL uses CI CD jobs path`() throws {
        let host = try #require(URL(string: "https://gitlab.example.com"))
        let builder = RepoWebURLBuilder(host: host, provider: .gitlab)

        #expect(
            builder.ciRunsURL(fullName: "platform/backend/widget")?.absoluteString ==
                "https://gitlab.example.com/platform/backend/widget/-/jobs"
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
