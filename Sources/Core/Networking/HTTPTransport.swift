import Foundation

/// The provider-specific parts of talking HTTP — everything else about a
/// request (ETags, caching, decoding, status handling) is shared.
struct HTTPPolicy: Sendable {
    let kind: ProviderKind
    /// Sent on every request: auth, API version, default `Accept`.
    let headers: [String: String]
    /// Maps a non-2xx response to an error. Return `nil` to fall back to
    /// the shared defaults (401 → invalid token, 429 → rate limited,
    /// otherwise unexpected status).
    var classifyError: @Sendable (HTTPURLResponse, Data) -> ProviderError? = { _, _ in nil }
    /// Reads the remaining budget off a response, if the provider reports one.
    var rateLimit: @Sendable (HTTPURLResponse) -> RateLimitStatus? = { _ in nil }
    /// Whether a list response has another page. Defaults to the
    /// `Link: <…>; rel="next"` header GitHub and GitLab both use.
    var hasNextPage: @Sendable (HTTPURLResponse, Data) -> Bool = { response, _ in
        HTTPTransport.linkHeaderHasNext(response)
    }
}

/// One per account (via its provider client). An `actor` because the
/// store fires several requests at once and every one of them writes the
/// rate-limit and ETag state.
actor HTTPTransport {
    private let policy: HTTPPolicy
    private let session: URLSession

    private(set) var lastKnownRateLimit: RateLimitStatus?

    /// Last good response per GET (keyed by URL + request headers), replayed
    /// on a `304 Not Modified`. Every GET sends its cached `ETag` back as
    /// `If-None-Match`; providers answer 304 when nothing changed, and on
    /// GitHub a 304 doesn't count against the rate limit — so a background
    /// poll of repos that haven't moved is effectively free. In memory
    /// only, and per account (ETags are scoped to the token).
    private var responseCache: [String: CachedResponse] = [:]
    private static let responseCacheLimit = 400

    private struct CachedResponse {
        let etag: String
        let data: Data
        let hasNextPage: Bool
    }

    /// No `URLCache`: the ETag handling above has to see the real 304s.
    /// With the shared session, Foundation's own cache would honor a
    /// provider's `max-age=60` and hand back up-to-a-minute-old data
    /// without asking — wrong for a refresh the user explicitly asked for.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    init(policy: HTTPPolicy, session: URLSession = HTTPTransport.defaultSession) {
        self.policy = policy
        self.session = session
    }

    /// Decoded body plus the pagination signal.
    func get<T: Decodable>(_ url: URL, headers: [String: String] = [:]) async throws -> (value: T, hasNextPage: Bool) {
        let result: (value: T, hasNextPage: Bool, response: HTTPURLResponse) = try await getWithResponse(url, headers: headers)
        return (result.value, result.hasNextPage)
    }

    /// `get`, plus the HTTP response itself — for providers that report
    /// things in headers (token scopes, a requested poll interval). On a 304
    /// it's the 304's response, which carries the same headers.
    func getWithResponse<T: Decodable>(_ url: URL, headers: [String: String] = [:]) async throws -> (value: T, hasNextPage: Bool, response: HTTPURLResponse) {
        var request = makeRequest(url, method: "GET", headers: headers)

        let cacheKey = url.absoluteString + " " + headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let cached = responseCache[cacheKey]
        if let cached {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        let (freshData, http) = try await send(request)
        let data: Data
        let hasNextPage: Bool
        if http.statusCode == 304, let cached {
            data = cached.data
            hasNextPage = cached.hasNextPage
        } else {
            try checkStatus(http, data: freshData)
            data = freshData
            hasNextPage = policy.hasNextPage(http, freshData)
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                if responseCache[cacheKey] == nil, responseCache.count >= Self.responseCacheLimit {
                    responseCache.remove(at: responseCache.startIndex)
                }
                responseCache[cacheKey] = CachedResponse(etag: etag, data: data, hasNextPage: hasNextPage)
            }
        }
        return (try decode(T.self, from: data), hasNextPage, http)
    }

    /// A body-less write (e.g. marking a notification read) — no JSON either way.
    func sendEmpty(_ method: String, _ url: URL) async throws {
        let (data, http) = try await send(makeRequest(url, method: method, headers: [:]))
        try checkStatus(http, data: data)
    }

    /// A write (or a GraphQL query) — JSON body in, decoded JSON out.
    func send<Body: Encodable, T: Decodable>(_ method: String, _ url: URL, body: Body, headers: [String: String] = [:]) async throws -> T {
        var request = makeRequest(url, method: method, headers: headers)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw ProviderError.decoding(policy.kind, error)
        }
        let (data, http) = try await send(request)
        try checkStatus(http, data: data)
        return try decode(T.self, from: data)
    }

    /// `rel="next"` in a `Link` header.
    static func linkHeaderHasNext(_ response: HTTPURLResponse) -> Bool {
        (response.value(forHTTPHeaderField: "Link") ?? "").contains("rel=\"next\"")
    }

    // MARK: - Plumbing

    private func makeRequest(_ url: URL, method: String, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (field, value) in policy.headers { request.setValue(value, forHTTPHeaderField: field) }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(policy.kind, error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.unexpectedStatus(policy.kind, 0)
        }
        if let limit = policy.rateLimit(http) { lastKnownRateLimit = limit }
        return (data, http)
    }

    private func checkStatus(_ http: HTTPURLResponse, data: Data) throws {
        guard !(200...299).contains(http.statusCode) else { return }
        if let error = policy.classifyError(http, data) { throw error }
        switch http.statusCode {
        case 401:
            throw ProviderError.invalidToken(policy.kind)
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(policy.kind, retryAfter: retryAfter)
        default:
            throw ProviderError.unexpectedStatus(policy.kind, http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ProviderError.decoding(policy.kind, error)
        }
    }
}
