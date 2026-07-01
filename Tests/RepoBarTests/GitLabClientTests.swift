import Foundation
@testable import RepoBarCore
import Testing

struct GitLabClientTests {
    @Test
    func `rejects insecure and credential-bearing hosts`() throws {
        #expect(throws: GitLabAPIError.self) {
            _ = try GitLabClient(apiHost: #require(URL(string: "http://gitlab.example.com/api/v4"))) { "token" }
        }
        #expect(throws: GitLabAPIError.self) {
            _ = try GitLabClient(apiHost: #require(URL(string: "https://user:secret@gitlab.example.com/api/v4"))) { "token" }
        }
        #expect(throws: GitLabAPIError.self) {
            _ = try HostingProviderHostNormalizer.normalize(
                #require(URL(string: "http://gitlab.example.com")),
                provider: .gitlab
            )
        }
    }

    @Test
    func `repository list maps issue and merge request counts`() async throws {
        let transport = GitLabRecordingTransport { request in
            let body: String
            switch request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }) {
            case "/api/v4/projects":
                body = """
                [{
                  "id": 7,
                  "name": "Widget",
                  "path": "widget",
                  "path_with_namespace": "platform/backend/widget",
                  "description": "A widget",
                  "web_url": "https://gitlab.example.com/platform/backend/widget",
                  "star_count": 3,
                  "forks_count": 1,
                  "archived": false,
                  "open_issues_count": 2,
                  "last_activity_at": "2026-06-30T12:00:00Z",
                  "namespace": {"path": "backend", "full_path": "platform/backend"},
                  "topics": ["swift"]
                }]
                """
            case "/api/v4/merge_requests":
                body = "[{\"project_id\":7},{\"project_id\":7}]"
            default:
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        let client = try Self.client(transport: transport)

        let repositories = try await client.repositoryList(limit: nil)
        let repository = try #require(repositories.first)
        let requests = await transport.requests

        #expect(repository.fullName == "platform/backend/widget")
        #expect(repository.openIssues == 2)
        #expect(repository.openPulls == 2)
        #expect(repository.discussionsEnabled == false)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "gitlab-token" })
        #expect(requests.allSatisfy { $0.url?.scheme == "https" })
    }

    @Test
    func `full repository hydrates counts pipeline and release`() async throws {
        let transport = GitLabRecordingTransport { request in
            let body: String
            switch request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }) {
            case "/api/v4/projects/platform%2Fbackend%2Fwidget":
                body = """
                {
                  "id": 7,
                  "name": "Widget",
                  "path": "widget",
                  "path_with_namespace": "platform/backend/widget",
                  "description": null,
                  "web_url": "https://gitlab.example.com/platform/backend/widget",
                  "star_count": 0,
                  "forks_count": 0,
                  "archived": false,
                  "open_issues_count": 2,
                  "last_activity_at": "2026-06-30T12:00:00Z",
                  "namespace": {"path": "backend", "full_path": "platform/backend"}
                }
                """
            case "/api/v4/projects/platform%2Fbackend%2Fwidget/issues":
                body = "[{\"iid\":1},{\"iid\":2}]"
            case "/api/v4/projects/platform%2Fbackend%2Fwidget/merge_requests":
                body = "[{\"iid\":3}]"
            case "/api/v4/projects/platform%2Fbackend%2Fwidget/pipelines":
                body = """
                [{
                  "id": 44,
                  "web_url": "https://gitlab.example.com/platform/backend/widget/-/pipelines/44",
                  "updated_at": "2026-06-30T13:00:00Z",
                  "created_at": "2026-06-30T12:55:00Z",
                  "status": "success",
                  "ref": "main",
                  "source": "push"
                }]
                """
            case "/api/v4/projects/platform%2Fbackend%2Fwidget/releases":
                body = """
                [{
                  "name": "1.0.0",
                  "tag_name": "v1.0.0",
                  "released_at": "2026-06-29T12:00:00Z",
                  "_links": {"self": "https://gitlab.example.com/platform/backend/widget/-/releases/v1.0.0"}
                }]
                """
            default:
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        let client = try Self.client(transport: transport)

        let repository = try await client.fullRepository(owner: "platform/backend", name: "widget")

        #expect(repository.openIssues == 2)
        #expect(repository.openPulls == 1)
        #expect(repository.ciStatus == CIStatus.passing)
        #expect(repository.ciRunCount == 1)
        #expect(repository.latestRelease?.tag == "v1.0.0")
        #expect(repository.discussionsEnabled == false)
    }

    @Test
    func `full repository tolerates disabled optional features`() async throws {
        let transport = GitLabRecordingTransport { request in
            let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }
            if path == "/api/v4/projects/platform%2Fbackend%2Fwidget" {
                let body = """
                {
                  "id": 7,
                  "name": "Widget",
                  "path": "widget",
                  "path_with_namespace": "platform/backend/widget",
                  "description": null,
                  "web_url": "https://gitlab.example.com/platform/backend/widget",
                  "star_count": 0,
                  "forks_count": 0,
                  "archived": false,
                  "open_issues_count": 2,
                  "last_activity_at": "2026-06-30T12:00:00Z",
                  "namespace": {"path": "backend", "full_path": "platform/backend"}
                }
                """
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (Data("{\"message\":\"feature disabled\"}".utf8), response)
        }
        let client = try Self.client(transport: transport)

        let repository = try await client.fullRepository(owner: "platform/backend", name: "widget")

        #expect(repository.openIssues == 2)
        #expect(repository.openPulls == 0)
        #expect(repository.ciStatus == CIStatus.unknown)
        #expect(repository.ciRunCount == 0)
        #expect(repository.latestRelease == nil)
    }

    @Test
    func `rejects response from another origin`() async throws {
        let transport = GitLabRecordingTransport { _ in
            let url = try #require(URL(string: "https://attacker.example/user"))
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{\"username\":\"alice\"}".utf8), response)
        }
        let client = try Self.client(transport: transport)

        await #expect(throws: GitLabAPIError.self) {
            _ = try await client.currentUser()
        }
    }

    private static func client(transport: GitLabRecordingTransport) throws -> GitLabClient {
        try GitLabClient(
            apiHost: #require(URL(string: "https://gitlab.example.com/api/v4")),
            tokenProvider: { "gitlab-token" },
            dataLoader: HTTPDataLoader { request in
                try await transport.data(for: request)
            }
        )
    }
}

private actor GitLabRecordingTransport {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, URLResponse)

    private let handler: Handler
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        self.requests.append(request)
        return try self.handler(request)
    }
}
