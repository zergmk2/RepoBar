import Foundation
import OSLog
import RepoBarCore

public enum PATAuthError: Error, LocalizedError {
    case invalidToken
    case forbidden(String)
    case networkError(Error)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            "Invalid token"
        case let .forbidden(message):
            message
        case let .networkError(error):
            error.localizedDescription
        case .invalidResponse:
            "Invalid response from server"
        }
    }
}

/// Handles Personal Access Token authentication as an alternative to OAuth.
/// PATs can be authorized for SAML SSO organizations in GitHub settings.
@MainActor
public final class PATAuthenticator {
    private let tokenStore: TokenStore
    private let signposter = OSSignposter(subsystem: "com.steipete.repobar", category: "pat-auth")
    private var cachedPAT: String?
    private var hasLoadedPAT = false
    private let dataLoader: HTTPDataLoader

    public init(
        tokenStore: TokenStore = .shared
    ) {
        self.tokenStore = tokenStore
        self.dataLoader = .noRedirects
    }

    init(tokenStore: TokenStore, session: URLSession) {
        self.tokenStore = tokenStore
        self.dataLoader = HTTPDataLoader { request in
            try await session.data(for: request)
        }
    }

    public func authenticate(pat: String, host: URL) async throws -> UserIdentity {
        try await self.authenticate(provider: .github, pat: pat, host: host)
    }

    /// Validates PAT via provider user endpoint, stores on success, returns UserIdentity.
    public func authenticate(provider: HostingProvider, pat: String, host: URL) async throws -> UserIdentity {
        let signpost = self.signposter.beginInterval("authenticate")
        defer { self.signposter.endInterval("authenticate", signpost) }

        let normalizedHost = try HostingProviderHostNormalizer.normalize(host, provider: provider)
        let apiHost = Self.apiHost(provider: provider, for: normalizedHost)
        let userURL = apiHost.appendingPathComponent("user")

        var request = URLRequest(url: userURL)
        switch provider {
        case .github:
            request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        case .gitlab:
            request.setValue(pat, forHTTPHeaderField: "PRIVATE-TOKEN")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.dataLoader.data(for: request)
        } catch {
            throw PATAuthError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PATAuthError.invalidResponse
        }
        guard Self.sameOrigin(httpResponse.url, userURL) else {
            throw PATAuthError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw PATAuthError.invalidToken
        case 403:
            let scopes = provider == .github ? "repo, read:org" : "read_api"
            throw PATAuthError.forbidden("Access forbidden. Token may lack required scopes (\(scopes))")
        default:
            throw PATAuthError.invalidResponse
        }

        struct GitHubUserResponse: Decodable {
            let login: String
        }

        struct GitLabUserResponse: Decodable {
            let username: String
        }

        let username: String
        do {
            switch provider {
            case .github:
                username = try JSONDecoder().decode(GitHubUserResponse.self, from: data).login
            case .gitlab:
                username = try JSONDecoder().decode(GitLabUserResponse.self, from: data).username
                let client = try GitLabClient(
                    apiHost: apiHost,
                    tokenProvider: { pat },
                    dataLoader: self.dataLoader
                )
                try await client.validateReadAPIScope()
            }
        } catch let GitLabAPIError.badStatus(code, _) where code == 401 {
            throw PATAuthError.invalidToken
        } catch let GitLabAPIError.badStatus(code, _) where code == 403 {
            throw PATAuthError.forbidden("Access forbidden. Token may lack required scopes (read_api)")
        } catch is GitLabAPIError {
            throw PATAuthError.invalidResponse
        } catch {
            if error is DecodingError {
                throw PATAuthError.invalidResponse
            }
            throw PATAuthError.networkError(error)
        }

        // Fixed legacy keys remain GitHub-only compatibility storage. Provider
        // accounts persist credentials under their account-scoped keys.
        if provider == .github {
            try self.tokenStore.savePAT(pat)
            self.cachedPAT = pat
            self.hasLoadedPAT = true
        }
        await DiagnosticsLogger.shared.message("PAT login succeeded.")

        return UserIdentity(username: username, host: normalizedHost)
    }

    /// Loads the stored PAT from Keychain.
    public func loadPAT() -> String? {
        if self.hasLoadedPAT { return self.cachedPAT }
        self.hasLoadedPAT = true
        let pat = try? self.tokenStore.loadPAT()
        self.cachedPAT = pat
        return pat
    }

    /// Clears the stored PAT.
    public func logout() async {
        self.tokenStore.clearPAT()
        self.cachedPAT = nil
        self.hasLoadedPAT = false
        await DiagnosticsLogger.shared.message("PAT cleared.")
    }

    /// Converts a GitHub host URL to its API endpoint.
    private static func apiHost(provider: HostingProvider, for host: URL) -> URL {
        switch provider {
        case .github:
            self.gitHubAPIHost(for: host)
        case .gitlab:
            Account.deriveAPIHost(provider: .gitlab, for: host)
        }
    }

    private static func gitHubAPIHost(for host: URL) -> URL {
        let hostString = host.host ?? "github.com"
        if hostString == "github.com" {
            return URL(string: "https://api.github.com")!
        }
        // Enterprise: use /api/v3 path
        return host.appendingPathComponent("api/v3")
    }

    private static func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }

        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }
}
