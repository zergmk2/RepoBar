import Foundation

public struct HTTPDataLoader: Sendable {
    public static let live = HTTPDataLoader { request in
        try await URLSession.shared.data(for: request)
    }

    private let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.load = load
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.load(request)
    }
}
