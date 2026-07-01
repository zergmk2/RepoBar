import Foundation

public struct GitLabCurrentUser: Decodable, Sendable {
    public let username: String
}

public struct GitLabPersonalAccessToken: Decodable, Sendable {
    public let scopes: [String]
}

public struct GitLabProjectItem: Decodable, Sendable {
    public let id: Int
    public let name: String
    public let path: String
    public let pathWithNamespace: String
    public let description: String?
    public let webURL: URL
    public let starCount: Int
    public let forksCount: Int
    public let archived: Bool
    public let openIssuesCount: Int?
    public let lastActivityAt: Date?
    public let namespace: Namespace
    public let tagList: [String]?
    public let topics: [String]?

    public struct Namespace: Decodable, Sendable {
        public let path: String
        public let fullPath: String

        enum CodingKeys: String, CodingKey {
            case path
            case fullPath = "full_path"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case pathWithNamespace = "path_with_namespace"
        case description
        case webURL = "web_url"
        case starCount = "star_count"
        case forksCount = "forks_count"
        case archived
        case openIssuesCount = "open_issues_count"
        case lastActivityAt = "last_activity_at"
        case namespace
        case tagList = "tag_list"
        case topics
    }
}

struct GitLabProjectReferenceItem: Decodable {
    let projectID: Int

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
    }
}

struct GitLabCountItem: Decodable {
    let iid: Int
}

public struct GitLabUserSummary: Decodable, Sendable {
    public let username: String?
    public let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case username
        case avatarURL = "avatar_url"
    }
}

public struct GitLabIssueItem: Decodable, Sendable {
    public let iid: Int
    public let title: String
    public let webURL: URL
    public let updatedAt: Date
    public let createdAt: Date?
    public let author: GitLabUserSummary?
    public let assignees: [GitLabUserSummary]?
    public let userNotesCount: Int?
    public let labels: [String]?

    enum CodingKeys: String, CodingKey {
        case iid
        case title
        case webURL = "web_url"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case author
        case assignees
        case userNotesCount = "user_notes_count"
        case labels
    }
}

public struct GitLabMergeRequestItem: Decodable, Sendable {
    public let iid: Int
    public let title: String
    public let webURL: URL
    public let updatedAt: Date
    public let createdAt: Date?
    public let state: String?
    public let mergedAt: Date?
    public let draft: Bool?
    public let author: GitLabUserSummary?
    public let userNotesCount: Int?
    public let labels: [String]?
    public let sourceBranch: String?
    public let targetBranch: String?
    public let description: String?

    enum CodingKeys: String, CodingKey {
        case iid
        case title
        case webURL = "web_url"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case state
        case mergedAt = "merged_at"
        case draft
        case author
        case userNotesCount = "user_notes_count"
        case labels
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
        case description
    }
}

public struct GitLabPipelineItem: Decodable, Sendable {
    public let id: Int
    public let webURL: URL
    public let updatedAt: Date?
    public let createdAt: Date?
    public let status: String?
    public let ref: String?
    public let source: String?
    public let user: GitLabUserSummary?

    enum CodingKeys: String, CodingKey {
        case id
        case webURL = "web_url"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case status
        case ref
        case source
        case user
    }
}

public struct GitLabJobItem: Decodable, Sendable {
    public let id: Int
    public let name: String
    public let webURL: URL?
    public let finishedAt: Date?
    public let startedAt: Date?
    public let createdAt: Date?
    public let status: String?
    public let ref: String?
    public let stage: String?
    public let user: GitLabUserSummary?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case webURL = "web_url"
        case finishedAt = "finished_at"
        case startedAt = "started_at"
        case createdAt = "created_at"
        case status
        case ref
        case stage
        case user
    }
}

public struct GitLabReleaseItem: Decodable, Sendable {
    public let name: String
    public let tagName: String
    public let releasedAt: Date?
    public let createdAt: Date?
    public let links: Links?
    public let author: GitLabUserSummary?
    public let assets: Assets?

    public struct Links: Decodable, Sendable {
        public let selfURL: URL?

        enum CodingKeys: String, CodingKey {
            case selfURL = "self"
        }
    }

    public struct Assets: Decodable, Sendable {
        public let count: Int?
        public let links: [AssetLink]?
        public let sources: [AssetLink]?
    }

    public struct AssetLink: Decodable, Sendable {
        public let name: String?
        public let url: URL?
    }

    enum CodingKeys: String, CodingKey {
        case name
        case tagName = "tag_name"
        case releasedAt = "released_at"
        case createdAt = "created_at"
        case links = "_links"
        case author
        case assets
    }
}

public struct GitLabTagItem: Decodable, Sendable {
    public let name: String
    public let commit: Commit

    public struct Commit: Decodable, Sendable {
        public let id: String
    }
}

public struct GitLabBranchItem: Decodable, Sendable {
    public let name: String
    public let protected: Bool
    public let commit: Commit

    public struct Commit: Decodable, Sendable {
        public let id: String
    }
}

public struct GitLabCommitItem: Decodable, Sendable {
    public let id: String
    public let title: String
    public let webURL: URL
    public let authoredDate: Date
    public let authorName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case webURL = "web_url"
        case authoredDate = "authored_date"
        case authorName = "author_name"
    }
}

public struct GitLabContributorItem: Decodable, Sendable {
    public let name: String
    public let commits: Int
}

public extension JSONDecoder {
    static var gitLab: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = GitLabDateFormatter.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid GitLab date: \(raw)")
        }
        return decoder
    }
}

enum GitLabDateFormatter {
    static func date(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? standard.date(from: raw)
    }
}
