import Foundation

private struct GitHubReferenceCacheLookupContext {
    let baseURL: URL
    let cache: HTTPResponseDiskCache
    let limit: Int
}

extension GitHubRestAPI {
    func cachedReferenceMatches(query: GitHubReferenceQuery, repositories: [Repository], limit: Int) async -> [GitHubReferenceMatch] {
        guard let cache = HTTPResponseDiskCache.standard() else { return [] }

        let context = await GitHubReferenceCacheLookupContext(
            baseURL: apiHost(),
            cache: cache,
            limit: limit
        )
        var matches: [GitHubReferenceMatch] = []
        for repo in repositories where repo.viewerCanRead && query.matches(repo: repo) {
            switch query {
            case let .issueNumber(number),
                 let .repositoryIssueNumber(_, number):
                matches.append(contentsOf: self.cachedIssueNumberMatches(query: query, number: number, repo: repo, context: context))
            case let .commitHash(hash),
                 let .repositoryCommitHash(_, hash):
                matches.append(contentsOf: self.cachedCommitMatches(query: query, hash: hash, repo: repo, context: context))
            }
        }
        return matches
    }

    func liveReferenceMatch(query: GitHubReferenceQuery, repositories: [Repository]) async -> GitHubReferenceMatch? {
        var matches: [GitHubReferenceMatch] = []
        for repo in repositories where repo.viewerCanRead && query.matches(repo: repo) {
            let match: GitHubReferenceMatch? = switch query {
            case let .issueNumber(number),
                 let .repositoryIssueNumber(_, number):
                await self.liveIssueNumberMatch(query: query, number: number, repo: repo)
            case let .commitHash(hash),
                 let .repositoryCommitHash(_, hash):
                await self.liveCommitMatch(query: query, hash: hash, repo: repo)
            }
            if let match {
                matches.append(match)
            }
        }
        return GitHubReferenceMatch.newestCreated(in: matches)
    }

    func liveReferenceMatch(query: GitHubReferenceQuery) async -> GitHubReferenceMatch? {
        switch query {
        case .issueNumber, .commitHash:
            nil
        case let .repositoryIssueNumber(repositoryFullName, number):
            await self.liveIssueNumberMatch(query: query, number: number, repositoryFullName: repositoryFullName)
        case let .repositoryCommitHash(repositoryFullName, hash):
            await self.liveCommitMatch(query: query, hash: hash, repositoryFullName: repositoryFullName)
        }
    }

    private func cachedIssueNumberMatches(
        query: GitHubReferenceQuery,
        number: Int,
        repo: Repository,
        context: GitHubReferenceCacheLookupContext
    ) -> [GitHubReferenceMatch] {
        var matches: [GitHubReferenceMatch] = []
        let issueURLs = self.cachedRecentIssueURLs(baseURL: context.baseURL, owner: repo.owner, name: repo.name)
        for url in issueURLs {
            guard let cached = context.cache.cached(url: url),
                  let issues = try? GitHubRecentDecoders.decodeRecentIssues(from: cached.data)
            else { continue }

            matches.append(contentsOf: issues.filter { $0.number == number }.map {
                GitHubReferenceMatch(
                    query: query,
                    title: $0.title,
                    url: $0.url,
                    repositoryFullName: repo.fullName,
                    kind: .issue,
                    state: .open,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            })
        }

        let pullURLs = self.cachedRecentPullRequestURLs(baseURL: context.baseURL, owner: repo.owner, name: repo.name, limit: context.limit)
        for url in pullURLs {
            guard let cached = context.cache.cached(url: url),
                  let pulls = try? GitHubRecentDecoders.decodeRecentPullRequests(from: cached.data)
            else { continue }

            matches.append(contentsOf: pulls.filter { $0.number == number }.map {
                GitHubReferenceMatch(
                    query: query,
                    title: $0.title,
                    url: $0.url,
                    repositoryFullName: repo.fullName,
                    kind: .pullRequest,
                    state: .open,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            })
        }
        return matches
    }

    private func cachedCommitMatches(
        query: GitHubReferenceQuery,
        hash: String,
        repo: Repository,
        context: GitHubReferenceCacheLookupContext
    ) -> [GitHubReferenceMatch] {
        let normalized = hash.lowercased()
        let urls = self.cachedRecentCommitURLs(baseURL: context.baseURL, owner: repo.owner, name: repo.name, limit: context.limit)
        var matches: [GitHubReferenceMatch] = []
        for url in urls {
            guard let cached = context.cache.cached(url: url),
                  let commits = try? GitHubRecentDecoders.decodeRecentCommits(from: cached.data)
            else { continue }

            matches.append(contentsOf: commits.filter { $0.sha.lowercased().hasPrefix(normalized) }.map {
                GitHubReferenceMatch(
                    query: query,
                    title: $0.message,
                    url: $0.url,
                    repositoryFullName: repo.fullName,
                    kind: .commit,
                    state: nil,
                    createdAt: $0.authoredAt,
                    updatedAt: $0.authoredAt
                )
            })
        }
        return matches
    }

    private func liveIssueNumberMatch(query: GitHubReferenceQuery, number: Int, repo: Repository) async -> GitHubReferenceMatch? {
        do {
            let token = try await tokenProvider()
            let baseURL = await apiHost()
            let url = baseURL.appending(path: "/repos/\(repo.owner)/\(repo.name)/issues/\(number)")
            let (data, _) = try await authorizedGet(url: url, token: token)
            let response = try GitHubDecoding.decode(IssueLookupResponse.self, from: data)
            return response.match(query: query, repositoryFullName: repo.fullName)
        } catch {
            return nil
        }
    }

    private func liveIssueNumberMatch(query: GitHubReferenceQuery, number: Int, repositoryFullName: String) async -> GitHubReferenceMatch? {
        guard let parts = query.repositoryOwnerAndName else { return nil }

        do {
            let baseURL = await apiHost()
            let url = baseURL.appending(path: "/repos/\(parts.owner)/\(parts.name)/issues/\(number)")
            let data = try await self.referenceLookupData(url: url)
            let response = try GitHubDecoding.decode(IssueLookupResponse.self, from: data)
            return response.match(query: query, repositoryFullName: repositoryFullName)
        } catch {
            return nil
        }
    }

    private func liveCommitMatch(query: GitHubReferenceQuery, hash: String, repo: Repository) async -> GitHubReferenceMatch? {
        do {
            let token = try await tokenProvider()
            let baseURL = await apiHost()
            let url = baseURL.appending(path: "/repos/\(repo.owner)/\(repo.name)/commits/\(hash)")
            let (data, _) = try await authorizedGet(url: url, token: token)
            let response = try GitHubDecoding.decode(CommitLookupResponse.self, from: data)
            return response.match(query: query, repositoryFullName: repo.fullName)
        } catch {
            return nil
        }
    }

    private func liveCommitMatch(query: GitHubReferenceQuery, hash: String, repositoryFullName: String) async -> GitHubReferenceMatch? {
        guard let parts = query.repositoryOwnerAndName else { return nil }

        do {
            let baseURL = await apiHost()
            let url = baseURL.appending(path: "/repos/\(parts.owner)/\(parts.name)/commits/\(hash)")
            let data = try await self.referenceLookupData(url: url)
            let response = try GitHubDecoding.decode(CommitLookupResponse.self, from: data)
            return response.match(query: query, repositoryFullName: repositoryFullName)
        } catch {
            return nil
        }
    }

    private func referenceLookupData(url: URL) async throws -> Data {
        if let token = try? await tokenProvider(), token.isEmpty == false {
            return try await authorizedGet(url: url, token: token, useETag: false).0
        }

        var request = URLRequest(url: url)
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.addValue("RepoBar", forHTTPHeaderField: "User-Agent")
        let (data, responseAny) = try await URLSession.shared.data(for: request)
        guard let response = responseAny as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw GitHubAPIError.badStatus(
                code: response.statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            )
        }

        return data
    }

    private func cachedRecentIssueURLs(baseURL: URL, owner: String, name: String) -> [URL] {
        (1 ... 3).compactMap { page in
            var components = URLComponents(url: baseURL.appending(path: "/repos/\(owner)/\(name)/issues"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "state", value: "open"),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "direction", value: "desc"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: "\(page)")
            ]
            return components.url
        }
    }

    private func cachedRecentPullRequestURLs(baseURL: URL, owner: String, name: String, limit: Int) -> [URL] {
        let limits = Array(Set([max(1, min(limit, 100)), 20, 100])).sorted()
        return limits.compactMap { limit in
            var components = URLComponents(url: baseURL.appending(path: "/repos/\(owner)/\(name)/pulls"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "state", value: "open"),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "direction", value: "desc"),
                URLQueryItem(name: "per_page", value: "\(limit)")
            ]
            return components.url
        }
    }

    private func cachedRecentCommitURLs(baseURL: URL, owner: String, name: String, limit: Int) -> [URL] {
        let limits = Array(Set([max(1, min(limit, 100)), 20, 100])).sorted()
        return limits.compactMap { limit in
            var components = URLComponents(url: baseURL.appending(path: "/repos/\(owner)/\(name)/commits"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "per_page", value: "\(limit)")]
            return components.url
        }
    }
}

private extension GitHubReferenceQuery {
    func matches(repo: Repository) -> Bool {
        guard let repositoryFullName else { return true }

        return repo.fullName.caseInsensitiveCompare(repositoryFullName) == .orderedSame
    }
}

private struct IssueLookupResponse: Decodable {
    let title: String
    let body: String?
    let htmlUrl: URL
    let state: String
    let createdAt: Date
    let updatedAt: Date
    let pullRequest: PullRequestMarker?
    let user: LookupUser?

    enum CodingKeys: String, CodingKey {
        case title, body, state, user
        case htmlUrl = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }

    func match(query: GitHubReferenceQuery, repositoryFullName: String) -> GitHubReferenceMatch {
        GitHubReferenceMatch(
            query: query,
            title: self.title,
            url: self.htmlUrl,
            repositoryFullName: repositoryFullName,
            kind: self.pullRequest == nil ? .issue : .pullRequest,
            state: self.referenceState,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt,
            bodyPreview: Self.bodyPreview(from: self.body),
            authorLogin: self.user?.login
        )
    }

    private var referenceState: GitHubReferenceState? {
        if self.pullRequest?.mergedAt != nil {
            return .merged
        }

        return GitHubReferenceState(rawValue: self.state.lowercased())
    }

    private static func bodyPreview(from body: String?) -> String? {
        guard let body else { return nil }

        let collapsed = body
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        guard collapsed.isEmpty == false else { return nil }

        let limit = 360
        return collapsed.count > limit
            ? "\(collapsed.prefix(limit - 1))…"
            : collapsed
    }
}

private struct PullRequestMarker: Decodable {
    let mergedAt: Date?

    enum CodingKeys: String, CodingKey {
        case mergedAt = "merged_at"
    }
}

private struct LookupUser: Decodable {
    let login: String
}

private struct CommitLookupResponse: Decodable {
    let htmlUrl: URL
    let commit: CommitDetail

    enum CodingKeys: String, CodingKey {
        case htmlUrl = "html_url"
        case commit
    }

    func match(query: GitHubReferenceQuery, repositoryFullName: String) -> GitHubReferenceMatch {
        let message = self.commit.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return GitHubReferenceMatch(
            query: query,
            title: title,
            url: self.htmlUrl,
            repositoryFullName: repositoryFullName,
            kind: .commit,
            state: nil,
            createdAt: self.commit.author.date,
            updatedAt: self.commit.author.date
        )
    }

    struct CommitDetail: Decodable {
        let message: String
        let author: CommitAuthor
    }

    struct CommitAuthor: Decodable {
        let date: Date
    }
}
