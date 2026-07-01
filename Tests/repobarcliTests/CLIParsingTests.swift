import Commander
@testable import repobarcli
import Testing

struct CLIParsingTests {
    @Test
    func `parse repo name splits owner and name`() throws {
        let result = try parseRepoName("steipete/RepoBar")
        #expect(result.owner == "steipete")
        #expect(result.name == "RepoBar")
    }

    @Test
    func `parse repo name trims whitespace and git suffix`() throws {
        let result = try parseRepoName("  steipete/RepoBar.git  ")
        #expect(result.owner == "steipete")
        #expect(result.name == "RepoBar")
    }

    @Test
    func `parse repo name accepts GitHub HTTPS URLs`() throws {
        let result = try parseRepoName("https://github.com/steipete/RepoBar")
        #expect(result.owner == "steipete")
        #expect(result.name == "RepoBar")
    }

    @Test
    func `parse repo name accepts GitHub URL subpages`() throws {
        let result = try parseRepoName("https://github.com/steipete/RepoBar/issues/1")
        #expect(result.owner == "steipete")
        #expect(result.name == "RepoBar")
    }

    @Test
    func `parse repo name accepts SSH remotes`() throws {
        let result = try parseRepoName("git@github.com:steipete/RepoBar.git")
        #expect(result.owner == "steipete")
        #expect(result.name == "RepoBar")
    }

    @Test
    func `parse clone remotes preserve route words in subgroup paths`() throws {
        let ssh = try parseRepoName("git@gitlab.example.com:platform/issues/widget.git")
        #expect(ssh.owner == "platform/issues")
        #expect(ssh.name == "widget")

        let https = try parseRepoName("https://gitlab.example.com/platform/actions/widget.git")
        #expect(https.owner == "platform/actions")
        #expect(https.name == "widget")
    }

    @Test
    func `parse repo name rejects missing slash`() {
        #expect(throws: ValidationError.self) {
            _ = try parseRepoName("RepoBar")
        }
    }

    @Test
    func `parse repo name preserves reserved words in raw subgroup paths`() throws {
        let result = try parseRepoName("platform/actions/widget")
        #expect(result.owner == "platform/actions")
        #expect(result.name == "widget")

        let reservedName = try parseRepoName("owner/issues")
        #expect(reservedName.owner == "owner")
        #expect(reservedName.name == "issues")
    }
}
