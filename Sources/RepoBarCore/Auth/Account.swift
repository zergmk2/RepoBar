import Foundation

/// Represents a single GitHub identity (account) configured in RepoBar.
///
/// Account identity is stable across re-login: the `id` is derived from
/// `host` authority + `username`, so the same user signing back in
/// on the same host always resolves to the same record.
public struct Account: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var provider: HostingProvider
    public var displayName: String
    public var username: String
    public var host: URL
    public var apiHost: URL
    public var authMethod: AuthMethod
    public var loopbackPort: Int
    public var clientID: String?
    public var addedAt: Date

    public init(
        id: String,
        provider: HostingProvider = .github,
        displayName: String,
        username: String,
        host: URL,
        apiHost: URL,
        authMethod: AuthMethod,
        loopbackPort: Int = RepoBarAuthDefaults.loopbackPort,
        clientID: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.username = username
        self.host = host
        self.apiHost = apiHost
        self.authMethod = authMethod
        self.loopbackPort = loopbackPort
        self.clientID = clientID
        self.addedAt = addedAt
    }

    /// Convenience initializer that derives `id`, `apiHost`, and `displayName`.
    public init(
        provider: HostingProvider = .github,
        username: String,
        host: URL,
        authMethod: AuthMethod,
        loopbackPort: Int = RepoBarAuthDefaults.loopbackPort,
        clientID: String? = nil,
        displayName: String? = nil,
        addedAt: Date = Date()
    ) {
        let id = Account.deriveID(provider: provider, host: host, username: username)
        let apiHost = Account.deriveAPIHost(provider: provider, for: host)
        let hostLabel = Account.hostAuthority(for: host)
        self.init(
            id: id,
            provider: provider,
            displayName: displayName ?? "\(username) @ \(hostLabel)",
            username: username,
            host: host,
            apiHost: apiHost,
            authMethod: authMethod,
            loopbackPort: loopbackPort,
            clientID: clientID,
            addedAt: addedAt
        )
    }

    /// Stable account ID, e.g. `github.com#alice` or `ghe.example.com:8443#bob`.
    public static func deriveID(host: URL, username: String) -> String {
        self.deriveID(provider: .github, host: host, username: username)
    }

    public static func deriveID(provider: HostingProvider, host: URL, username: String) -> String {
        let hostName = self.hostAuthority(for: host)
        let user = username.lowercased()
        let base = "\(hostName)#\(user)"
        switch provider {
        case .github:
            return base
        case .gitlab:
            return "gitlab:\(base)"
        }
    }

    public static func hostAuthority(for host: URL) -> String {
        let hostName = (host.host ?? "github.com").lowercased()
        if let port = host.port {
            return "\(hostName):\(port)"
        }
        return hostName
    }

    /// Resolves the REST API host for a given GitHub web host.
    ///
    /// - github.com -> https://api.github.com
    /// - Enterprise hosts (https://ghe.example.com) -> /api/v3
    public static func deriveAPIHost(for host: URL) -> URL {
        self.deriveAPIHost(provider: .github, for: host)
    }

    public static func deriveAPIHost(provider: HostingProvider, for host: URL) -> URL {
        switch provider {
        case .github:
            self.deriveGitHubAPIHost(for: host)
        case .gitlab:
            host.appendingPathComponent("api/v4")
        }
    }

    private static func deriveGitHubAPIHost(for host: URL) -> URL {
        let hostName = (host.host ?? "github.com").lowercased()
        if hostName == "github.com" {
            return URL(string: "https://api.github.com")!
        }
        return host.appendingPathComponent("api/v3")
    }

    /// Human-friendly label, e.g. `alice @ github.com`.
    public var usernameAtHost: String {
        let hostName = Self.hostAuthority(for: self.host)
        return "\(self.username) @ \(hostName)"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case displayName
        case username
        case host
        case apiHost
        case authMethod
        case loopbackPort
        case clientID
        case addedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.provider = try container.decodeIfPresent(HostingProvider.self, forKey: .provider) ?? .github
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.username = try container.decode(String.self, forKey: .username)
        self.host = try container.decode(URL.self, forKey: .host)
        self.apiHost = try container.decode(URL.self, forKey: .apiHost)
        self.authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
        self.loopbackPort = try container.decodeIfPresent(Int.self, forKey: .loopbackPort) ?? RepoBarAuthDefaults.loopbackPort
        self.clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
        self.addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    }
}

/// Selection mask for which accounts contribute repositories to menus and views.
public enum AccountSelection: Equatable, Hashable, Sendable {
    case all
    case only(Set<String>)

    public func isVisible(_ accountID: String) -> Bool {
        switch self {
        case .all:
            true
        case let .only(ids):
            ids.contains(accountID)
        }
    }

    public var visibleIDs: Set<String>? {
        switch self {
        case .all:
            nil
        case let .only(ids):
            ids
        }
    }
}

extension AccountSelection: Codable {
    private enum Kind: String, Codable {
        case all
        case only
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case ids
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .all
        switch kind {
        case .all:
            self = .all
        case .only:
            let ids = try container.decodeIfPresent([String].self, forKey: .ids) ?? []
            self = .only(Set(ids))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try container.encode(Kind.all, forKey: .kind)
        case let .only(ids):
            try container.encode(Kind.only, forKey: .kind)
            try container.encode(ids.sorted(), forKey: .ids)
        }
    }
}
