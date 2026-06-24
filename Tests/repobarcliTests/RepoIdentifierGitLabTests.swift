@testable import repobarcli
import Testing

struct RepoIdentifierGitLabTests {
    @Test
    func `parse repo name preserves gitlab subgroup path`() throws {
        let repo = try parseRepoName("platform/backend/widget")

        #expect(repo.owner == "platform/backend")
        #expect(repo.name == "widget")
        #expect(repo.fullName == "platform/backend/widget")
    }

    @Test
    func `parse ssh remote preserves gitlab subgroup path`() throws {
        let repo = try parseRepoName("git@gitlab.example.com:platform/backend/widget.git")

        #expect(repo.owner == "platform/backend")
        #expect(repo.name == "widget")
        #expect(repo.fullName == "platform/backend/widget")
    }
}
