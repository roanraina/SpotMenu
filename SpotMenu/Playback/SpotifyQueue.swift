import Foundation

struct SpotifyQueue: Decodable {
    struct Item: Decodable {
        struct Artist: Decodable {
            let name: String
        }

        let name: String
        let artists: [Artist]?
        let show: Artist?

        var subtitle: String? {
            artists?.map(\.name).joined(separator: ", ") ?? show?.name
        }
    }

    let queue: [Item]

    enum LoadError: Error {
        case signInRequired
        case accessDenied
        case rateLimited
        case unavailable
    }

    private static let endpoint = URL(string: "https://api.spotify.com/v1/me/player/queue")!
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()
    @MainActor private static var retryAfter: Date?

    @MainActor static func load() async throws -> [Item] {
        if let retryAfter, retryAfter > Date() {
            throw LoadError.rateLimited
        }

        var response = try await request(forceRefresh: false)
        if response.http.statusCode == 401 {
            response = try await request(forceRefresh: true)
        }
        return try items(from: response.data, response: response.http)
    }

    @MainActor static func items(from data: Data, response: HTTPURLResponse) throws -> [Item] {
        switch response.statusCode {
        case 200:
            return try JSONDecoder().decode(Self.self, from: data).queue
        case 204:
            return []
        case 401:
            throw LoadError.signInRequired
        case 403:
            throw LoadError.accessDenied
        case 429:
            let delay = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init) ?? 5
            retryAfter = Date().addingTimeInterval(max(1, delay))
            throw LoadError.rateLimited
        default:
            throw LoadError.unavailable
        }
    }

    @MainActor private static func request(
        forceRefresh: Bool
    ) async throws -> (data: Data, http: HTTPURLResponse) {
        try Task.checkCancellation()
        let token: String? = await withCheckedContinuation { continuation in
            SpotifyAuthManager.shared.getAccessToken(forceRefresh: forceRefresh) {
                continuation.resume(returning: $0)
            }
        }
        try Task.checkCancellation()
        guard let token else { throw LoadError.signInRequired }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LoadError.unavailable }
        return (data, http)
    }
}
