import Foundation

public enum HostingProvider: String, Codable, CaseIterable, Sendable {
    case github
    case gitlab

    public var label: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        }
    }
}

public enum HostingProviderHostNormalizer {
    public static func normalize(_ host: URL, provider: HostingProvider) throws -> URL {
        switch provider {
        case .github:
            try self.normalizeGitHubHost(host)
        case .gitlab:
            try self.normalizeGitLabHost(host)
        }
    }

    private static func normalizeGitHubHost(_ host: URL) throws -> URL {
        guard var components = URLComponents(url: host, resolvingAgainstBaseURL: false) else {
            throw GitHubAPIError.invalidHost
        }

        if components.scheme == nil { components.scheme = "https" }
        guard components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil
        else {
            throw GitHubAPIError.invalidHost
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let cleaned = components.url else { throw GitHubAPIError.invalidHost }

        return cleaned
    }

    private static func normalizeGitLabHost(_ host: URL) throws -> URL {
        guard var components = URLComponents(url: host, resolvingAgainstBaseURL: false) else {
            throw GitLabAPIError.invalidHost
        }

        if components.scheme == nil { components.scheme = "https" }
        guard components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil
        else {
            throw GitLabAPIError.invalidHost
        }

        components.scheme = "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let cleaned = components.url else { throw GitLabAPIError.invalidHost }

        return cleaned
    }
}
