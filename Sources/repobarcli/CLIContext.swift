import Commander
import Foundation
import RepoBarCore

struct AuthContext {
    let client: GitHubClient
    let settings: UserSettings
    let host: URL
}

struct ProviderAuthContext {
    let provider: HostingProvider
    let repositoryClient: any RepositoryServiceClient
    let githubClient: GitHubClient?
    let gitlabClient: GitLabClient?
    let settings: UserSettings
    let host: URL
}

struct RepoIdentifier: Equatable {
    let owner: String
    let name: String

    var fullName: String {
        "\(self.owner)/\(self.name)"
    }

    func webURL(baseHost: URL) -> URL {
        baseHost.appending(path: "/\(self.fullName)")
    }
}

func makeAuthenticatedClient() async throws -> AuthContext {
    let settings = cliSettingsStore().load()
    if let account = settings.resolvedActiveAccount() {
        guard account.provider == .github else {
            throw ValidationError("This command requires an active GitHub account")
        }
        guard (try? TokenStore.shared.loadTokens(accountID: account.id)) != nil
            || (try? TokenStore.shared.loadPAT(accountID: account.id)) != nil
        else {
            throw CLIError.notAuthenticated
        }

        let archiveSettings = settings.githubArchives
        let client = GitHubClient(
            accountID: account.id,
            archiveSettingsProvider: { archiveSettings }
        )
        await client.setAPIHost(account.apiHost)
        await client.setTokenProvider { @Sendable () async throws -> OAuthTokens? in
            if account.authMethod == .pat, let pat = try? TokenStore.shared.loadPAT(accountID: account.id) {
                return OAuthTokens(accessToken: pat, refreshToken: "", expiresAt: nil)
            }
            return try await OAuthTokenRefresher().refreshIfNeeded(
                host: account.host,
                accountID: account.id
            )
        }
        return AuthContext(client: client, settings: settings, host: account.host)
    }

    guard (try? TokenStore.shared.load()) != nil else {
        throw CLIError.notAuthenticated
    }

    let host = settings.enterpriseHost ?? settings.githubHost
    let apiHost: URL = if let enterprise = settings.enterpriseHost {
        enterprise.appending(path: "/api/v3")
    } else {
        RepoBarAuthDefaults.apiHost
    }

    let archiveSettings = settings.githubArchives
    let client = GitHubClient(archiveSettingsProvider: { archiveSettings })
    await client.setAPIHost(apiHost)
    await client.setTokenProvider { @Sendable () async throws -> OAuthTokens? in
        try await OAuthTokenRefresher().refreshIfNeeded(host: host)
    }
    return AuthContext(client: client, settings: settings, host: host)
}

func makeProviderAuthenticatedClient() async throws -> ProviderAuthContext {
    let settings = cliSettingsStore().load()
    guard let account = settings.resolvedActiveAccount() else {
        let context = try await makeAuthenticatedClient()
        return ProviderAuthContext(
            provider: .github,
            repositoryClient: context.client,
            githubClient: context.client,
            gitlabClient: nil,
            settings: context.settings,
            host: context.host
        )
    }

    switch account.provider {
    case .github:
        guard (try? TokenStore.shared.loadTokens(accountID: account.id)) != nil
            || (try? TokenStore.shared.loadPAT(accountID: account.id)) != nil
        else {
            throw CLIError.notAuthenticated
        }

        let context = try await makeAuthenticatedClient()
        return ProviderAuthContext(
            provider: .github,
            repositoryClient: context.client,
            githubClient: context.client,
            gitlabClient: nil,
            settings: context.settings,
            host: context.host
        )
    case .gitlab:
        guard (try? TokenStore.shared.loadPAT(accountID: account.id)) != nil else {
            throw CLIError.notAuthenticated
        }

        let client = try GitLabClient(apiHost: account.apiHost) {
            if let pat = try? TokenStore.shared.loadPAT(accountID: account.id) {
                return pat
            }
            throw CLIError.notAuthenticated
        }
        return ProviderAuthContext(
            provider: .gitlab,
            repositoryClient: client,
            githubClient: nil,
            gitlabClient: client,
            settings: settings,
            host: account.host
        )
    }
}

func mirrorAccountCredentialsToLegacy(_ account: Account) throws {
    guard account.provider == .github else { return }

    if TokenStore.shared.mirrorAccountCredentialsToLegacy(accountID: account.id, authMethod: account.authMethod) == false {
        throw CLIError.notAuthenticated
    }
}

func mirrorActiveAccountIntoSettings(_ account: Account, settings: inout UserSettings) {
    guard account.provider == .github else { return }

    settings.githubHost = account.host
    settings.enterpriseHost = account.host.host?.lowercased() == "github.com" ? nil : account.host
    settings.authMethod = account.authMethod
    settings.loopbackPort = account.loopbackPort
}

func mirrorResolvedActiveAccount(settings: inout UserSettings) {
    guard let active = settings.resolvedActiveAccount() else {
        TokenStore.shared.clear()
        return
    }
    guard active.provider == .github else { return }

    mirrorActiveAccountIntoSettings(active, settings: &settings)
    _ = TokenStore.shared.mirrorAccountCredentialsToLegacy(
        accountID: active.id,
        authMethod: active.authMethod
    )
}

func makeRepoURL(baseHost: URL, owner: String, name: String) -> URL {
    RepoIdentifier(owner: owner, name: name).webURL(baseHost: baseHost)
}

func requireRepoName(_ name: String?) throws -> String {
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), name.isEmpty == false else {
        throw ValidationError("Missing repository name (owner/name)")
    }

    return name
}

func requireRepoIdentifier(_ name: String?) throws -> RepoIdentifier {
    try parseRepoName(requireRepoName(name))
}

func parseRepoName(_ value: String) throws -> RepoIdentifier {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
        throw ValidationError("Repository must be in namespace/name format")
    }

    if let remoteParts = repoPathFromRemote(trimmed) {
        return try RepoIdentifier(validatingPathParts: remoteParts)
    }

    let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2 else {
        throw ValidationError("Repository must be in namespace/name format")
    }

    return try RepoIdentifier(validatingPathParts: parts)
}

private func repoPathFromRemote(_ value: String) -> [String]? {
    if let url = URL(string: value), let host = url.host, host.isEmpty == false {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }

        let scheme = url.scheme?.lowercased()
        let isCloneRemote = scheme == "ssh" || scheme == "git" || parts.last?.hasSuffix(".git") == true
        return isCloneRemote ? parts : repositoryPathParts(from: parts)
    }

    guard let separator = value.firstIndex(of: ":") else { return nil }

    let prefix = value[..<separator]
    guard prefix.contains("@") else { return nil }

    let path = String(value[value.index(after: separator)...])
    let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard parts.count >= 2 else { return nil }

    // SCP-style syntax is a clone remote, so route-like subgroup names are literal path components.
    return parts
}

private func repositoryPathParts(from parts: [String]) -> [String] {
    let stopComponents: Set = [
        "-", "actions", "activity", "branches", "commits", "discussions", "issues",
        "merge_requests", "pipelines", "pull", "releases", "tags", "tree", "workflows"
    ]
    if let stop = parts.firstIndex(where: { stopComponents.contains($0) }), stop >= 2 {
        return Array(parts[..<stop])
    }
    return parts
}

private extension RepoIdentifier {
    init(validatingPathParts rawParts: [String]) throws {
        guard rawParts.count >= 2 else {
            throw ValidationError("Repository must be in namespace/name format")
        }

        var parts = rawParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts[parts.count - 1].hasSuffix(".git") {
            parts[parts.count - 1].removeLast(4)
        }
        guard parts.allSatisfy({ $0.isEmpty == false }) else {
            throw ValidationError("Repository must be in namespace/name format")
        }

        self.init(owner: parts.dropLast().joined(separator: "/"), name: parts[parts.count - 1])
    }

    init(validatingOwner rawOwner: String, name rawName: String) throws {
        let owner = rawOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(".git") {
            name.removeLast(4)
        }

        guard owner.isEmpty == false, name.isEmpty == false else {
            throw ValidationError("Repository must be in owner/name format")
        }
        guard owner.contains("/") == false, name.contains("/") == false else {
            throw ValidationError("Repository must be in owner/name format")
        }

        self.init(owner: owner, name: name)
    }
}
