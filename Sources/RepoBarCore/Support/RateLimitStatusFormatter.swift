import Foundation

public struct RateLimitDisplayRow: Codable, Equatable, Sendable {
    public let text: String
    public let resource: String?
    public let quotaText: String?
    public let resetText: String?
    public let percentRemaining: Double?

    public init(
        text: String,
        resource: String? = nil,
        quotaText: String? = nil,
        resetText: String? = nil,
        percentRemaining: Double? = nil
    ) {
        self.text = text
        self.resource = resource
        self.quotaText = quotaText
        self.resetText = resetText
        self.percentRemaining = percentRemaining
    }
}

public struct RateLimitDisplaySection: Codable, Equatable, Sendable {
    public let title: String?
    public let rows: [String]
    public let resourceRows: [RateLimitDisplayRow]

    public init(title: String?, rows: [String]) {
        self.title = title
        self.rows = rows
        self.resourceRows = rows.map { RateLimitDisplayRow(text: $0) }
    }

    public init(title: String?, resourceRows: [RateLimitDisplayRow]) {
        self.title = title
        self.rows = resourceRows.map(\.text)
        self.resourceRows = resourceRows
    }
}

public enum RateLimitStatusFormatter {
    public static func compactSummary(
        diagnostics: DiagnosticsSummary,
        cacheSummary: RepoBarCacheSummary?,
        now: Date = Date()
    ) -> String {
        if let reset = diagnostics.rateLimitReset {
            return "Limited · resets \(RelativeFormatter.string(from: reset, relativeTo: now))"
        }
        let nextCooldown = diagnostics.endpointCooldowns
            .filter { $0.retryAfter > now }
            .min(by: { $0.retryAfter < $1.retryAfter })
        if let cooldown = nextCooldown {
            return "Endpoint cooldown · \(Self.endpointCooldownText(cooldown, now: now))"
        }

        var rows: [String] = []
        if let rest = diagnostics.restRateLimit {
            rows.append(Self.snapshotText(label: "REST", snapshot: rest, now: now, compact: true))
        }
        if let graphQL = diagnostics.graphQLRateLimit {
            rows.append(Self.snapshotText(label: "GraphQL", snapshot: graphQL, now: now, compact: true))
        }
        if rows.isEmpty, let cacheSummary {
            rows = Self.observedRateLimitRows(from: cacheSummary)
                .prefix(2)
                .map { Self.cachedResponseText($0, now: now, compact: true) }
        }
        if rows.isEmpty, let active = cacheSummary?.rateLimits.first {
            rows.append(Self.activeLimitText(active, now: now, compact: true))
        }

        return rows.isEmpty ? "No rate-limit data yet" : rows.joined(separator: " · ")
    }

    public static func sections(
        diagnostics: DiagnosticsSummary,
        cacheSummary: RepoBarCacheSummary?,
        now: Date = Date()
    ) -> [RateLimitDisplaySection] {
        var sections: [RateLimitDisplaySection] = []
        var currentRows: [String] = []

        if let resources = diagnostics.rateLimitResources {
            sections.append(contentsOf: Self.liveResourceSections(from: resources, now: now))
        } else if let rest = diagnostics.restRateLimit {
            currentRows.append(Self.snapshotText(label: "REST", snapshot: rest, now: now))
            if let graphQL = diagnostics.graphQLRateLimit {
                currentRows.append(Self.snapshotText(label: "GraphQL", snapshot: graphQL, now: now))
            }
        }
        if let reset = diagnostics.rateLimitReset {
            currentRows.append("Blocked until \(RelativeFormatter.string(from: reset, relativeTo: now)).")
        }
        if let error = diagnostics.lastRateLimitError {
            currentRows.append(error)
        }
        if currentRows.isEmpty == false {
            sections.append(RateLimitDisplaySection(title: nil, rows: currentRows))
        }
        let endpointCooldowns = diagnostics.endpointCooldowns.filter { $0.retryAfter > now }
        if endpointCooldowns.isEmpty == false {
            sections.append(RateLimitDisplaySection(
                title: "Endpoint Cooldowns",
                rows: endpointCooldowns.map { Self.endpointCooldownText($0, now: now) }
            ))
        }

        if let cacheSummary {
            if diagnostics.rateLimitResources == nil {
                let observed = Self.observedRateLimitRows(from: cacheSummary)
                if observed.isEmpty == false {
                    sections.append(contentsOf: Self.observedSections(from: observed, now: now))
                }
            }
            if cacheSummary.rateLimits.isEmpty == false {
                sections.append(RateLimitDisplaySection(
                    title: "Active Limits",
                    rows: cacheSummary.rateLimits.map { Self.activeLimitText($0, now: now) }
                ))
            }
        }

        return sections.isEmpty
            ? [RateLimitDisplaySection(title: nil, rows: ["No rate-limit data yet"])]
            : sections
    }

    private static func observedSections(
        from rows: [RepoBarCachedResponseSummary],
        now: Date
    ) -> [RateLimitDisplaySection] {
        let grouped = Dictionary(grouping: rows) { Self.resourceGroup(for: $0.rateLimitResource) }
        return ResourceGroup.allCases.compactMap { group in
            guard let rows = grouped[group], rows.isEmpty == false else { return nil }

            return RateLimitDisplaySection(
                title: group.title,
                resourceRows: rows.map { Self.cachedResponseRow($0, now: now) }
            )
        }
    }

    private static func liveResourceSections(
        from snapshot: RateLimitResourcesSnapshot,
        now: Date
    ) -> [RateLimitDisplaySection] {
        let grouped = Dictionary(grouping: Self.sortedResources(snapshot.resources)) { resource, _ in
            Self.resourceGroup(for: resource)
        }
        return ResourceGroup.allCases.compactMap { group in
            guard let resources = grouped[group], resources.isEmpty == false else { return nil }

            return RateLimitDisplaySection(
                title: group.title,
                resourceRows: resources.map { resource, value in
                    Self.rateLimitRow(RateLimitTextInput(
                        resource: resource,
                        remaining: value.remaining,
                        limit: value.limit,
                        reset: value.reset
                    ), now: now, compact: false)
                }
            )
        }
    }

    public static func observedRateLimitRows(from summary: RepoBarCacheSummary) -> [RepoBarCachedResponseSummary] {
        var seen: Set<String> = []
        var rows: [RepoBarCachedResponseSummary] = []
        for response in summary.latestResponses {
            guard let resource = response.rateLimitResource, resource.isEmpty == false else { continue }
            guard seen.insert(resource).inserted else { continue }

            rows.append(response)
        }
        return rows
    }

    private static func endpointCooldownText(_ cooldown: EndpointCooldownSummary, now: Date) -> String {
        let label = if let repository = cooldown.repository {
            "\(repository) \(cooldown.endpoint)"
        } else {
            cooldown.endpoint
        }

        return "\(label) · retry \(RelativeFormatter.string(from: cooldown.retryAfter, relativeTo: now))"
    }

    private static func sortedResources<T>(_ resources: [String: T]) -> [(String, T)] {
        resources.sorted { lhs, rhs in
            let leftGroup = Self.resourceGroup(for: lhs.key).rawValue
            let rightGroup = Self.resourceGroup(for: rhs.key).rawValue
            if leftGroup != rightGroup { return leftGroup < rightGroup }
            return lhs.key < rhs.key
        }
    }

    private static func snapshotText(label: String, snapshot: RateLimitSnapshot, now: Date, compact: Bool = false) -> String {
        let text = Self.rateLimitText(RateLimitTextInput(
            resource: snapshot.resource,
            remaining: snapshot.remaining,
            limit: snapshot.limit,
            reset: snapshot.reset
        ), now: now, compact: compact)
        return "\(label): \(text)"
    }

    private static func cachedResponseText(_ row: RepoBarCachedResponseSummary, now: Date, compact: Bool = false) -> String {
        self.rateLimitText(RateLimitTextInput(
            resource: row.rateLimitResource,
            remaining: row.rateLimitRemaining,
            limit: row.rateLimitLimit,
            reset: row.rateLimitReset
        ), now: now, compact: compact)
    }

    private static func cachedResponseRow(_ row: RepoBarCachedResponseSummary, now: Date) -> RateLimitDisplayRow {
        self.rateLimitRow(RateLimitTextInput(
            resource: row.rateLimitResource,
            remaining: row.rateLimitRemaining,
            limit: row.rateLimitLimit,
            reset: row.rateLimitReset
        ), now: now, compact: false)
    }

    private static func activeLimitText(_ row: RepoBarRateLimitSummary, now: Date, compact: Bool = false) -> String {
        let reset = RelativeFormatter.string(from: row.resetAt, relativeTo: now)
        let remaining = row.remaining.map { compact ? "\(Self.shortCount($0)) left" : "\($0) left" } ?? "blocked"
        let base = "\(row.resource): \(remaining), resets \(reset)"
        if compact || row.lastError?.isEmpty != false {
            return base
        }
        return "\(base) · \(row.lastError ?? "")"
    }

    private static func resourceGroup(for resource: String?) -> ResourceGroup {
        switch resource {
        case "core", "rate":
            .restCore
        case "search", "code_search":
            .restSearch
        case "graphql":
            .graphQL
        case "integration_manifest":
            .gitHubApp
        case "dependency_snapshots", "dependency_sbom":
            .dependencies
        case "code_scanning_upload", "code_scanning_autofix":
            .codeScanning
        case "actions_runner_registration":
            .actions
        case "scim", "audit_log", "source_import":
            .enterpriseAndImport
        default:
            .other
        }
    }

    private static func rateLimitText(_ input: RateLimitTextInput, now: Date, compact: Bool) -> String {
        self.rateLimitRow(input, now: now, compact: compact).text
    }

    private static func rateLimitRow(
        _ input: RateLimitTextInput,
        now: Date,
        compact: Bool
    ) -> RateLimitDisplayRow {
        var parts = [input.resource ?? "unknown"]
        var quotaText: String?
        var resetText: String?
        var percentRemaining: Double?
        if let remaining = input.remaining, let limit = input.limit {
            let remainingText = compact ? Self.shortCount(remaining) : "\(remaining)"
            let limitText = compact ? Self.shortCount(limit) : "\(limit)"
            quotaText = compact ? "\(remainingText)/\(limitText) left" : "\(remainingText)/\(limitText)"
            parts.append(quotaText ?? "")
            if limit > 0 {
                percentRemaining = min(100, max(0, (Double(remaining) / Double(limit)) * 100))
            }
        } else if let remaining = input.remaining {
            let remainingText = compact ? Self.shortCount(remaining) : "\(remaining)"
            quotaText = compact ? "\(remainingText) left" : remainingText
            parts.append(quotaText ?? "")
        }
        if let reset = input.reset {
            let verb = reset > now ? "resets" : "reset"
            resetText = "\(verb) \(RelativeFormatter.string(from: reset, relativeTo: now))"
            parts.append(resetText ?? "")
        }
        return RateLimitDisplayRow(
            text: parts.joined(separator: compact ? " " : " · "),
            resource: input.resource,
            quotaText: quotaText,
            resetText: resetText,
            percentRemaining: percentRemaining
        )
    }

    private static func shortCount(_ value: Int) -> String {
        if value >= 1000 {
            let rounded = Double(value) / 1000
            return rounded.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(rounded))K"
                : String(format: "%.1fK", rounded)
        }
        return "\(value)"
    }

    private struct RateLimitTextInput {
        let resource: String?
        let remaining: Int?
        let limit: Int?
        let reset: Date?
    }

    private enum ResourceGroup: Int, CaseIterable {
        case restCore
        case restSearch
        case graphQL
        case gitHubApp
        case dependencies
        case codeScanning
        case actions
        case enterpriseAndImport
        case other

        var title: String {
            switch self {
            case .restCore:
                "REST Core"
            case .restSearch:
                "REST Search"
            case .graphQL:
                "GraphQL"
            case .gitHubApp:
                "GitHub App"
            case .dependencies:
                "Dependency Metadata"
            case .codeScanning:
                "Code Scanning"
            case .actions:
                "Actions"
            case .enterpriseAndImport:
                "Enterprise / Import"
            case .other:
                "Other Resources"
            }
        }
    }
}
