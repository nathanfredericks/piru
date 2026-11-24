import Foundation

/// Requests are confined to the configured relay. Redirects are refused even on the
/// same origin: a redirected admin request carries two different credentials.
nonisolated struct SyncTransport: Sendable {
    enum Failure: LocalizedError {
        case unconfigured
        case malformed
        case oversized
        case http(status: Int, code: String)

        var errorDescription: String? {
            switch self {
            case .unconfigured: String(localized: "Journal Sync needs a configured service URL.")
            case .malformed: String(localized: "The sync service returned an invalid response.")
            case .oversized: String(localized: "The sync response is too large.")
            case let .http(status, _): String(localized: "Journal Sync request failed (HTTP \(status)).")
            }
        }
    }

    let base: URL
    let session: URLSession

    init(url: URL, session: URLSession = SyncTransport.relaySession) throws {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, ["", "/", "/v1", "/v1/"].contains(parts.path)
        else { throw Failure.unconfigured }
        var allowed = parts.scheme == "https"
        #if DEBUG
            allowed = allowed || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        #endif
        guard allowed else { throw Failure.unconfigured }
        parts.path = "/v1"
        guard let base = parts.url else { throw Failure.unconfigured }
        self.base = base
        self.session = session
    }

    static func configured() throws -> Self {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PIRU_SYNC_URL") as? String,
              let url = URL(string: raw) else { throw Failure.unconfigured }
        return try Self(url: url)
    }

    final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void,
        ) { completionHandler(nil) }
    }

    static let relaySession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    func request<Response: Decodable>(
        _ method: String, _ path: [String], query: [URLQueryItem] = [],
        bearer: String? = nil, owner: String? = nil, requestID: String? = nil,
        body: Data? = nil, as _: Response.Type = Response.self,
    ) async throws -> Response {
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }),
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw Failure.malformed }
        parts.path += "/" + path.joined(separator: "/")
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw Failure.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if let owner { request.setValue(owner, forHTTPHeaderField: "X-Owner-Bearer") }
        if let requestID { request.setValue(requestID, forHTTPHeaderField: "Idempotency-Key") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        guard (200 ..< 300).contains(http.statusCode) else {
            let server = try? JSONDecoder().decode(ServerError.self, from: data)
            throw Failure.http(status: http.statusCode, code: server?.error ?? "")
        }
        guard data.count <= 64 * 1024 * 1024 else { throw Failure.oversized }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private struct ServerError: Decodable { let error: String }
}
