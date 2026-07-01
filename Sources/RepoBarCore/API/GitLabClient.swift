import Foundation

public enum GitLabAPIError: Error, LocalizedError, Sendable {
    case invalidHost
    case badStatus(code: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Invalid GitLab host."
        case let .badStatus(code, message):
            "GitLab returned \(code): \(message)"
        case .invalidResponse:
            "Invalid GitLab response."
        }
    }
}

public actor GitLabClient {
    public private(set) var apiHost: URL
    private let tokenProvider: @Sendable () async throws -> String
    private let dataLoader: HTTPDataLoader

    public init(
        apiHost: URL,
        tokenProvider: @escaping @Sendable () async throws -> String,
        dataLoader: HTTPDataLoader = .noRedirects
    ) throws {
        guard apiHost.scheme?.lowercased() == "https",
              apiHost.host?.isEmpty == false,
              apiHost.user == nil,
              apiHost.password == nil
        else {
            throw GitLabAPIError.invalidHost
        }

        self.apiHost = apiHost
        self.tokenProvider = tokenProvider
        self.dataLoader = dataLoader
    }

    public func currentUser() async throws -> UserIdentity {
        let user = try await self.get(path: "/user", decode: GitLabCurrentUser.self)
        return UserIdentity(username: user.username, host: self.webHostURL())
    }

    public func repositoryList(limit: Int?) async throws -> [Repository] {
        async let projectItems = self.projectItems(limit: limit)
        async let mergeRequestCounts = self.openMergeRequestCountsByProject()
        let (items, counts) = try await (projectItems, mergeRequestCounts)
        return items.map { Repository.from(gitLabProject: $0, openPulls: counts[$0.id] ?? 0) }
    }

    public func activityRepositories(limit: Int?) async throws -> [Repository] {
        try await self.repositoryList(limit: limit)
    }

    public func fullRepository(owner: String, name: String) async throws -> Repository {
        let pathWithNamespace = "\(owner)/\(name)"
        let issuesPath = self.projectPath(owner: owner, name: name, suffix: "/issues")
        let mergeRequestsPath = self.projectPath(owner: owner, name: name, suffix: "/merge_requests")
        async let item = self.project(pathWithNamespace: pathWithNamespace)
        async let issueCountTask = self.openItemCount(path: issuesPath)
        async let pullCountTask = self.openItemCount(path: mergeRequestsPath)
        async let runsTask = self.recentWorkflowRuns(owner: owner, name: name, limit: 8)
        async let releasesTask = self.recentReleases(owner: owner, name: name, limit: 1)
        let project = try await item

        // GitLab projects can disable individual features. Their endpoints then return an error even
        // though the project itself is readable, so optional metadata must not block repository hydration.
        let pullCount = await (try? pullCountTask) ?? 0
        var repository = Repository.from(gitLabProject: project, openPulls: pullCount)
        if let issueCount = try? await issueCountTask {
            repository.openIssues = issueCount
        }
        let recentRuns = await (try? runsTask) ?? []
        repository.ciStatus = recentRuns.first?.status ?? .unknown
        repository.ciRunCount = recentRuns.count
        repository.latestRelease = try? await releasesTask.first.map {
            Release(name: $0.name, tag: $0.tag, publishedAt: $0.publishedAt, url: $0.url)
        }
        repository.discussionsEnabled = false
        return repository
    }

    public func recentIssues(owner: String, name: String, limit: Int = 20) async throws -> [RepoIssueSummary] {
        let items = try await self.get(
            path: self.projectPath(owner: owner, name: name, suffix: "/issues"),
            queryItems: self.recentQueryItems(limit: limit, extra: [
                URLQueryItem(name: "state", value: "opened"),
                URLQueryItem(name: "order_by", value: "updated_at"),
                URLQueryItem(name: "sort", value: "desc")
            ]),
            decode: [GitLabIssueItem].self
        )
        return items.map {
            RepoIssueSummary(
                number: $0.iid,
                title: $0.title,
                url: $0.webURL,
                updatedAt: $0.updatedAt,
                createdAt: $0.createdAt,
                authorLogin: $0.author?.username,
                authorAvatarURL: $0.author?.avatarURL,
                assigneeLogins: ($0.assignees ?? []).compactMap(\.username),
                commentCount: $0.userNotesCount ?? 0,
                labels: ($0.labels ?? []).map { RepoIssueLabel(name: $0, colorHex: "") }
            )
        }
    }

    public func recentPullRequests(owner: String, name: String, limit: Int = 20) async throws -> [RepoPullRequestSummary] {
        let items = try await self.get(
            path: self.projectPath(owner: owner, name: name, suffix: "/merge_requests"),
            queryItems: self.recentQueryItems(limit: limit, extra: [
                URLQueryItem(name: "state", value: "opened"),
                URLQueryItem(name: "order_by", value: "updated_at"),
                URLQueryItem(name: "sort", value: "desc")
            ]),
            decode: [GitLabMergeRequestItem].self
        )
        return items.map {
            RepoPullRequestSummary(
                number: $0.iid,
                title: $0.title,
                url: $0.webURL,
                updatedAt: $0.updatedAt,
                createdAt: $0.createdAt,
                state: $0.state == "closed" ? .closed : .open,
                mergedAt: $0.mergedAt,
                authorLogin: $0.author?.username,
                authorAvatarURL: $0.author?.avatarURL,
                isDraft: $0.draft ?? false,
                commentCount: $0.userNotesCount ?? 0,
                reviewCommentCount: 0,
                labels: ($0.labels ?? []).map { RepoIssueLabel(name: $0, colorHex: "") },
                headRefName: $0.sourceBranch,
                baseRefName: $0.targetBranch,
                bodyPreview: Self.preview($0.description)
            )
        }
    }

    public func recentWorkflowRuns(owner: String, name: String, limit: Int = 20) async throws -> [RepoWorkflowRunSummary] {
        let jobLimit = max(1, min(limit, 100))
        let items = try await self.get(
            path: self.projectPath(owner: owner, name: name, suffix: "/pipelines"),
            queryItems: self.recentQueryItems(limit: jobLimit, extra: [
                URLQueryItem(name: "order_by", value: "id"),
                URLQueryItem(name: "sort", value: "desc")
            ]),
            decode: [GitLabPipelineItem].self
        )
        return items.map {
            RepoWorkflowRunSummary(
                name: "Pipeline #\($0.id)",
                url: $0.webURL,
                updatedAt: $0.updatedAt ?? $0.createdAt ?? Date.distantPast,
                status: Self.ciStatus(fromGitLabStatus: $0.status),
                conclusion: $0.status,
                branch: $0.ref,
                event: $0.source,
                actorLogin: $0.user?.username,
                actorAvatarURL: $0.user?.avatarURL,
                runNumber: $0.id
            )
        }
    }

    public func recentReleases(owner: String, name: String, limit: Int = 20) async throws -> [RepoReleaseSummary] {
        let items = try await self.get(
            path: self.projectPath(owner: owner, name: name, suffix: "/releases"),
            queryItems: self.recentQueryItems(limit: limit, extra: [
                URLQueryItem(name: "order_by", value: "released_at"),
                URLQueryItem(name: "sort", value: "desc")
            ]),
            decode: [GitLabReleaseItem].self
        )
        return items.map { item in
            let assets = ((item.assets?.links ?? []) + (item.assets?.sources ?? [])).compactMap { asset -> RepoReleaseAssetSummary? in
                guard let name = asset.name, let url = asset.url else { return nil }

                return RepoReleaseAssetSummary(name: name, sizeBytes: nil, downloadCount: 0, url: url)
            }
            return RepoReleaseSummary(
                name: item.name,
                tag: item.tagName,
                url: item.links?.selfURL ?? self.webURL(owner: owner, name: name, suffix: "/-/releases/\(item.tagName)"),
                publishedAt: item.releasedAt ?? item.createdAt ?? Date.distantPast,
                isPrerelease: false,
                authorLogin: item.author?.username,
                authorAvatarURL: item.author?.avatarURL,
                assetCount: item.assets?.count ?? assets.count,
                downloadCount: 0,
                assets: assets
            )
        }
    }

    public func recentTags(owner: String, name: String, limit: Int = 20) async throws -> [RepoTagSummary] {
        let items = try await self.get(
            path: self.projectPath(owner: owner, name: name, suffix: "/repository/tags"),
            queryItems: self.recentQueryItems(limit: limit),
            decode: [GitLabTagItem].self
        )
        return items.map { RepoTagSummary(name: $0.name, commitSHA: $0.commit.id) }
    }

    public func recentBranches(owner: String, name: String, limit: Int = 20) async throws -> [RepoBranchSummary] {
        let items = try await self.get(
            path: self.projectPath(owner: owner, name: name, suffix: "/repository/branches"),
            queryItems: self.recentQueryItems(limit: limit),
            decode: [GitLabBranchItem].self
        )
        return items.map { RepoBranchSummary(name: $0.name, commitSHA: $0.commit.id, isProtected: $0.protected) }
    }

    public func recentCommits(owner: String, name: String, limit: Int = 20) async throws -> RepoCommitList {
        let items = try await self.get(
            path: self.projectPath(owner: owner, name: name, suffix: "/repository/commits"),
            queryItems: self.recentQueryItems(limit: limit),
            decode: [GitLabCommitItem].self
        )
        return RepoCommitList(
            items: items.map {
                RepoCommitSummary(
                    sha: $0.id,
                    message: $0.title,
                    url: $0.webURL,
                    authoredAt: $0.authoredDate,
                    authorName: $0.authorName,
                    authorLogin: nil,
                    authorAvatarURL: nil,
                    repoFullName: "\(owner)/\(name)"
                )
            },
            totalCount: nil
        )
    }

    public func topContributors(owner: String, name: String, limit: Int = 20) async throws -> [RepoContributorSummary] {
        let items = try await self.get(
            path: self.projectPath(owner: owner, name: name, suffix: "/repository/contributors"),
            queryItems: self.recentQueryItems(limit: limit),
            decode: [GitLabContributorItem].self
        )
        return items.map { RepoContributorSummary(login: $0.name, avatarURL: nil, url: nil, contributions: $0.commits) }
    }

    public func recentDiscussions(owner _: String, name _: String, limit _: Int = 20) async throws -> [RepoDiscussionSummary] {
        []
    }

    public func project(pathWithNamespace: String) async throws -> GitLabProjectItem {
        let encoded = Self.encodedProjectPath(pathWithNamespace)
        return try await self.get(path: "/projects/\(encoded)", decode: GitLabProjectItem.self)
    }

    private func projectItems(limit: Int?) async throws -> [GitLabProjectItem] {
        let pageSize = max(1, min(limit ?? 100, 100))
        var collected: [GitLabProjectItem] = []
        var page = 1

        while true {
            var queryItems = GitLabRestAPI.projectsQueryItems()
            queryItems.append(URLQueryItem(name: "per_page", value: "\(pageSize)"))
            queryItems.append(URLQueryItem(name: "page", value: "\(page)"))
            let pageItems = try await self.get(
                path: "/projects",
                queryItems: queryItems,
                decode: [GitLabProjectItem].self
            )
            collected.append(contentsOf: pageItems)
            if let limit, collected.count >= limit {
                return Array(collected.prefix(limit))
            }
            if pageItems.count < pageSize {
                return collected
            }
            page += 1
        }
    }

    private func openMergeRequestCountsByProject() async throws -> [Int: Int] {
        var counts: [Int: Int] = [:]
        var page = 1
        while true {
            let items = try await self.get(
                path: "/merge_requests",
                queryItems: [
                    URLQueryItem(name: "scope", value: "all"),
                    URLQueryItem(name: "state", value: "opened"),
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: "\(page)")
                ],
                decode: [GitLabProjectReferenceItem].self
            )
            for item in items {
                counts[item.projectID, default: 0] += 1
            }
            guard items.count == 100 else { return counts }

            page += 1
        }
    }

    private func openItemCount(path: String) async throws -> Int {
        var count = 0
        var page = 1
        while true {
            let items = try await self.get(
                path: path,
                queryItems: [
                    URLQueryItem(name: "state", value: "opened"),
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: "\(page)")
                ],
                decode: [GitLabCountItem].self
            )
            count += items.count
            guard items.count == 100 else { return count }

            page += 1
        }
    }

    private func get<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        decode type: T.Type
    ) async throws -> T {
        let url = try self.url(path: path, queryItems: queryItems)
        let data = try await self.getData(url: url)
        return try JSONDecoder.gitLab.decode(type, from: data)
    }

    private func getData(url: URL) async throws -> Data {
        let token = try await self.tokenProvider()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("RepoBar", forHTTPHeaderField: "User-Agent")

        let (data, responseAny) = try await self.dataLoader.data(for: request)
        guard let response = responseAny as? HTTPURLResponse else {
            throw GitLabAPIError.invalidResponse
        }
        guard Self.sameOrigin(response.url, url) else {
            throw GitLabAPIError.invalidResponse
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw GitLabAPIError.badStatus(
                code: response.statusCode,
                message: Self.statusMessage(for: response.statusCode, data: data)
            )
        }

        return data
    }

    private static func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }

        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }

    private func url(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents(url: self.apiHost, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = self.apiHost.path.trimmingTrailingSlash + path
        if queryItems.isEmpty == false {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else { throw GitLabAPIError.invalidHost }

        return url
    }

    private func webHostURL() -> URL {
        var components = URLComponents()
        components.scheme = self.apiHost.scheme ?? "https"
        components.host = self.apiHost.host
        components.port = self.apiHost.port
        return components.url ?? URL(string: "https://gitlab.com")!
    }

    static func encodedProjectPath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    private func projectPath(owner: String, name: String, suffix: String) -> String {
        "/projects/\(Self.encodedProjectPath("\(owner)/\(name)"))\(suffix)"
    }

    private func recentQueryItems(limit: Int, extra: [URLQueryItem] = []) -> [URLQueryItem] {
        extra + [URLQueryItem(name: "per_page", value: "\(max(1, min(limit, 100)))")]
    }

    private func webURL(owner: String, name: String, suffix: String) -> URL {
        self.webHostURL().appending(path: "\(owner)/\(name)\(suffix)")
    }

    private static func ciStatus(fromGitLabStatus status: String?) -> CIStatus {
        switch status {
        case "success":
            .passing
        case "failed", "canceled", "skipped":
            .failing
        case "created", "waiting_for_resource", "preparing", "pending", "running", "manual", "scheduled":
            .pending
        default:
            .unknown
        }
    }

    private static func preview(_ text: String?) -> String? {
        guard let text else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        return String(trimmed.prefix(280))
    }

    private static func statusMessage(for status: Int, data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = object["message"] {
            return "\(message)"
        }
        return HTTPURLResponse.localizedString(forStatusCode: status)
    }
}

private extension String {
    var trimmingTrailingSlash: String {
        self.hasSuffix("/") ? String(self.dropLast()) : self
    }
}
