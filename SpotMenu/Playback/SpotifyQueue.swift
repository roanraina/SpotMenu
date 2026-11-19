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

    let queue: [Item?]

    enum LoadError: LocalizedError {
        case signInRequired
        case insufficientScope
        case accessDenied
        case rateLimited
        case unexpectedStatus(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .signInRequired:
                return "Connect Spotify to see your queue."
            case .insufficientScope:
                return "Reconnect Spotify to grant queue access."
            case .accessDenied:
                return "Spotify denied queue access (403). Check your Spotify developer app and its allowed users."
            case .rateLimited:
                return "Spotify is limiting requests. Try refreshing in a moment."
            case .unexpectedStatus(let status):
                return "Spotify returned an error (\(status)). Try refreshing."
            case .invalidResponse:
                return "Spotify returned an unreadable queue response."
            }
        }
    }

    private struct ErrorResponse: Decodable {
        struct Details: Decodable {
            let message: String?
        }

        let error: Details
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
            do {
                return try JSONDecoder().decode(Self.self, from: data).queue.compactMap { $0 }
            } catch {
                throw LoadError.invalidResponse
            }
        case 204:
            return []
        case 401:
            throw LoadError.signInRequired
        case 403:
            let authenticate = response.value(forHTTPHeaderField: "WWW-Authenticate")
            let payload = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if authenticate?.localizedCaseInsensitiveContains("insufficient_scope") == true
                || payload?.error.message?.localizedCaseInsensitiveContains("insufficient client scope") == true
            {
                throw LoadError.insufficientScope
            }
            throw LoadError.accessDenied
        case 429:
            let delay = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init) ?? 5
            retryAfter = Date().addingTimeInterval(max(1, delay))
            throw LoadError.rateLimited
        default:
            throw LoadError.unexpectedStatus(response.statusCode)
        }
    }

    @MainActor private static func request(
        forceRefresh: Bool
    ) async throws -> (data: Data, http: HTTPURLResponse) {
        try Task.checkCancellation()
        let token: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                SpotifyAuthManager.shared.getAccessToken(forceRefresh: forceRefresh) {
                    continuation.resume(returning: $0)
                }
            }
        }
        try Task.checkCancellation()
        guard let token else { throw LoadError.signInRequired }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LoadError.invalidResponse }
        return (data, http)
    }
}
