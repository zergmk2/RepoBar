import Foundation

/// Provider-neutral repository operations shared by the app and CLI.
public protocol RepositoryServiceClient: Sendable {
    func currentUser() async throws -> UserIdentity
    func repositoryList(limit: Int?) async throws -> [Repository]
    func cachedRepositoryList(limit: Int?) async throws -> [Repository]
    func activityRepositories(limit: Int?) async throws -> [Repository]
    func fullRepository(owner: String, name: String) async throws -> Repository
    func fullRepository(owner: String, name: String, options: RepositoryDetailOptions) async throws -> Repository
    func latestRelease(owner: String, name: String) async throws -> Release?
    func recentIssues(owner: String, name: String, limit: Int) async throws -> [RepoIssueSummary]
    func recentPullRequests(owner: String, name: String, limit: Int) async throws -> [RepoPullRequestSummary]
    func recentReleases(owner: String, name: String, limit: Int) async throws -> [RepoReleaseSummary]
    func recentWorkflowRuns(owner: String, name: String, limit: Int) async throws -> [RepoWorkflowRunSummary]
    func recentDiscussions(owner: String, name: String, limit: Int) async throws -> [RepoDiscussionSummary]
    func recentTags(owner: String, name: String, limit: Int) async throws -> [RepoTagSummary]
    func recentBranches(owner: String, name: String, limit: Int) async throws -> [RepoBranchSummary]
    func topContributors(owner: String, name: String, limit: Int) async throws -> [RepoContributorSummary]
    func recentCommits(owner: String, name: String, limit: Int) async throws -> RepoCommitList
}

extension GitHubClient: RepositoryServiceClient {
    public func fullRepository(owner: String, name: String) async throws -> Repository {
        try await self.fullRepository(owner: owner, name: name, options: .default)
    }

    public func recentPullRequests(owner: String, name: String, limit: Int) async throws -> [RepoPullRequestSummary] {
        try await self.recentPullRequests(
            owner: owner,
            name: name,
            limit: limit,
            state: .open,
            includeCommentCounts: false
        )
    }
}

extension GitLabClient: RepositoryServiceClient {
    public func cachedRepositoryList(limit: Int?) async throws -> [Repository] {
        try await self.repositoryList(limit: limit)
    }

    public func fullRepository(
        owner: String,
        name: String,
        options _: RepositoryDetailOptions
    ) async throws -> Repository {
        try await self.fullRepository(owner: owner, name: name)
    }

    public func latestRelease(owner: String, name: String) async throws -> Release? {
        try await self.recentReleases(owner: owner, name: name, limit: 1).first.map {
            Release(name: $0.name, tag: $0.tag, publishedAt: $0.publishedAt, url: $0.url)
        }
    }
}
