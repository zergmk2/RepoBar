import Foundation
import RepoBarCore

struct RepoWebURLBuilder {
    let host: URL
    let provider: HostingProvider

    init(host: URL, provider: HostingProvider = .github) {
        self.host = host
        self.provider = provider
    }

    func repoURL(fullName: String) -> URL? {
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }

        switch self.provider {
        case .github:
            guard parts.count == 2 else { return nil }

        case .gitlab:
            guard parts.count >= 2 else { return nil }
        }

        return self.repoPathURL(components: parts.map(String.init))
    }

    func repoPathURL(fullName: String, path: String) -> URL? {
        let components = path.split(separator: "/").map(String.init)
        return self.repoPathURL(fullName: fullName, components: components)
    }

    func issuesURL(fullName: String) -> URL? {
        self.providerPathURL(fullName: fullName, github: ["issues"], gitlab: ["-", "issues"])
    }

    func pullsURL(fullName: String) -> URL? {
        self.providerPathURL(fullName: fullName, github: ["pulls"], gitlab: ["-", "merge_requests"])
    }

    func actionsURL(fullName: String) -> URL? {
        self.repoPathURL(fullName: fullName, components: ["actions"])
    }

    func ciRunsURL(fullName: String) -> URL? {
        switch self.provider {
        case .github:
            self.actionsURL(fullName: fullName)
        case .gitlab:
            self.repoPathURL(fullName: fullName, components: ["-", "pipelines"])
        }
    }

    func discussionsURL(fullName: String) -> URL? {
        guard self.provider == .github else { return nil }

        return self.repoPathURL(fullName: fullName, components: ["discussions"])
    }

    func tagsURL(fullName: String) -> URL? {
        self.providerPathURL(fullName: fullName, github: ["tags"], gitlab: ["-", "tags"])
    }

    func branchesURL(fullName: String) -> URL? {
        self.providerPathURL(fullName: fullName, github: ["branches"], gitlab: ["-", "branches"])
    }

    func commitsURL(fullName: String) -> URL? {
        self.providerPathURL(fullName: fullName, github: ["commits"], gitlab: ["-", "commits"])
    }

    func contributorsURL(fullName: String) -> URL? {
        self.providerPathURL(fullName: fullName, github: ["graphs", "contributors"], gitlab: ["-", "graphs"])
    }

    func releasesURL(fullName: String) -> URL? {
        self.providerPathURL(fullName: fullName, github: ["releases"], gitlab: ["-", "releases"])
    }

    func tagURL(fullName: String, tag: String) -> URL? {
        let prefix = self.provider == .gitlab ? ["-", "tree"] : ["tree"]
        return self.repoPathURL(fullName: fullName, components: prefix + tag.split(separator: "/").map(String.init))
    }

    func branchURL(fullName: String, branch: String) -> URL? {
        let prefix = self.provider == .gitlab ? ["-", "tree"] : ["tree"]
        return self.repoPathURL(fullName: fullName, components: prefix + branch.split(separator: "/").map(String.init))
    }

    private func providerPathURL(fullName: String, github: [String], gitlab: [String]) -> URL? {
        self.repoPathURL(fullName: fullName, components: self.provider == .github ? github : gitlab)
    }

    private func repoPathURL(fullName: String, components: [String]) -> URL? {
        guard var url = self.repoURL(fullName: fullName) else { return nil }

        for component in components where component.isEmpty == false {
            url.appendPathComponent(component)
        }
        return url
    }

    private func repoPathURL(components: [String]) -> URL {
        var url = self.host
        for component in components where component.isEmpty == false {
            url.appendPathComponent(component)
        }
        return url
    }
}
