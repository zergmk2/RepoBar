import Foundation

public struct HTTPDataLoader: Sendable {
    public static let live = HTTPDataLoader { request in
        try await URLSession.shared.data(for: request)
    }

    /// Credential-bearing requests must not follow redirects: URLSession may
    /// otherwise forward provider tokens to an unrelated redirect target.
    public static let noRedirects = HTTPDataLoader { request in
        try await RedirectBlockingSession.shared.data(for: request)
    }

    private let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.load = load
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.load(request)
    }
}

private enum RedirectBlockingSession {
    static let delegate = RedirectBlockingDelegate()
    static let shared = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
}

private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
