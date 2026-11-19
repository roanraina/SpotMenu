import AppKit
import CryptoKit
import Foundation
import Security

class SpotifyAuthManager: ObservableObject {
    static let shared = SpotifyAuthManager()

    private var clientID: String? {
        UserDefaults.standard.string(forKey: "spotify.clientID")
    }
    private let redirectURI = "com.github.kmikiy.spotmenu://callback"
    private let tokenURL = "https://accounts.spotify.com/api/token"
    private let authURL = "https://accounts.spotify.com/authorize"

    private let keychainService = "com.github.kmikiy.spotmenu.spotify.auth"
    private let accessTokenKey = "accessToken"
    private let refreshTokenKey = "refreshToken"
    private let expiryDateKey = "tokenExpiry"
    private let credentialsKey = "spotifySession"
    private var pendingAuthorization: (state: String, verifier: String)?
    private let credentialsLock = NSLock()
    private var sessionCredentials: Credentials?

    private struct Credentials: Codable {
        let clientID: String
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    @Published var didAuthenticate = false
    @Published private(set) var connectionIsSessionOnly = false

    // MARK: - Public Interface

    static func authorizationScopes(likingEnabled: Bool) -> [String] {
        let queueScopes = [
            "user-read-currently-playing",
            "user-read-playback-state",
        ]
        return likingEnabled
            ? queueScopes + ["user-library-read", "user-library-modify"]
            : queueScopes
    }

    func startAuthentication(likingEnabled: Bool) {
        guard let clientID = clientID, !clientID.isEmpty else {
            print("Missing Spotify Client ID")
            return
        }

        let codeVerifier = generateCodeVerifier()
        let state = generateCodeVerifier()
        pendingAuthorization = (state, codeVerifier)
        let codeChallenge = codeChallengeSHA256(codeVerifier)
        let scope = Self.authorizationScopes(likingEnabled: likingEnabled)
            .joined(separator: " ")

        var components = URLComponents(string: authURL)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "state", value: state),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: codeChallenge),
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    func handleRedirect(url: URL) {
        guard
            url.scheme == "com.github.kmikiy.spotmenu",
            url.host == "callback",
            let pending = pendingAuthorization,
            let parameters = URLComponents(
                url: url, resolvingAgainstBaseURL: false
            )?.queryItems,
            parameters.first(where: { $0.name == "state" })?.value == pending.state
        else { return }

        pendingAuthorization = nil
        guard let code = parameters.first(where: { $0.name == "code" })?.value
        else { return }
        requestAccessToken(code: code, codeVerifier: pending.verifier)
    }

    func getAccessToken(
        forceRefresh: Bool = false,
        completion: @escaping (String?) -> Void
    ) {
        guard let clientID, let credentials = credentials(for: clientID) else {
            completion(nil)
            return
        }

        if !forceRefresh, credentials.expiresAt > Date(), !credentials.accessToken.isEmpty {
            completion(credentials.accessToken)
        } else {
            refreshAccessToken(credentials, completion: completion)
        }
    }

    func checkAuthenticationStatus(completion: @escaping (Bool) -> Void) {
        getAccessToken { token in
            completion(token != nil)
        }
    }

    // MARK: - Spotify Liked Songs API

    func checkIfTrackIsLiked(
        trackID: String,
        completion: @escaping (Bool?) -> Void
    ) {
        getAccessToken { token in
            guard let token = token,
                let url = URL(
                    string:
                        "https://api.spotify.com/v1/me/tracks/contains?ids=\(trackID)"
                )
            else {
                completion(nil)
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )

            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data = data,
                    let result = try? JSONDecoder().decode(
                        [Bool].self,
                        from: data
                    ),
                    let isLiked = result.first
                else {
                    completion(nil)
                    return
                }
                completion(isLiked)
            }.resume()
        }
    }

    func addTrackToLiked(trackID: String, completion: ((Bool) -> Void)? = nil) {
        getAccessToken { token in
            guard let token = token,
                let url = URL(string: "https://api.spotify.com/v1/me/tracks")
            else {
                completion?(false)
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = try? JSONEncoder().encode(["ids": [trackID]])

            URLSession.shared.dataTask(with: request) { _, response, _ in
                let success = (response as? HTTPURLResponse)?.statusCode == 200
                completion?(success)
            }.resume()
        }
    }

    func removeTrackFromLiked(
        trackID: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        getAccessToken { token in
            guard let token = token,
                let url = URL(string: "https://api.spotify.com/v1/me/tracks")
            else {
                completion?(false)
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = try? JSONEncoder().encode(["ids": [trackID]])

            URLSession.shared.dataTask(with: request) { _, response, _ in
                let success = (response as? HTTPURLResponse)?.statusCode == 200
                completion?(success)
            }.resume()
        }
    }

    // MARK: - Private Logic

    private func requestAccessToken(code: String, codeVerifier: String) {
        guard let clientID = clientID, !clientID.isEmpty else {
            print("Missing Spotify Client ID")
            return
        }

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"

        let bodyParams = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": codeVerifier,
        ]

        request.httpBody =
            bodyParams
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let accessToken = json["access_token"] as? String,
                let refreshToken = json["refresh_token"] as? String,
                let expiresIn = json["expires_in"] as? Double
            else {
                DispatchQueue.main.async { self.didAuthenticate = false }
                return
            }

            let credentials = Credentials(
                clientID: clientID, accessToken: accessToken, refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(expiresIn)
            )
            let saved = self.storeCredentials(credentials)

            DispatchQueue.main.async {
                self.connectionIsSessionOnly = !saved
                self.didAuthenticate = true
            }
        }.resume()
    }

    private func refreshAccessToken(
        _ credentials: Credentials, completion: @escaping (String?) -> Void
    ) {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"

        let bodyParams = [
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": credentials.clientID,
        ]

        request.httpBody =
            bodyParams
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let accessToken = json["access_token"] as? String
            else {
                completion(nil)
                return
            }

            let renewed = Credentials(
                clientID: credentials.clientID, accessToken: accessToken,
                refreshToken: json["refresh_token"] as? String ?? credentials.refreshToken,
                expiresAt: Date().addingTimeInterval(json["expires_in"] as? Double ?? 3600)
            )
            let saved = self.storeCredentials(renewed)

            DispatchQueue.main.async {
                self.connectionIsSessionOnly = !saved
                completion(accessToken)
            }
        }.resume()
    }

    // MARK: - PKCE Utility

    private func generateCodeVerifier() -> String {
        let bytes = [UInt8].random(count: 64)
        return Data(bytes).base64URLEncodedString()
    }

    private func codeChallengeSHA256(_ verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }
}

// MARK: - Secure Storage Helpers

extension SpotifyAuthManager {
    private func credentials(for clientID: String) -> Credentials? {
        if let current = credentialsLock.withLock({ sessionCredentials }), current.clientID == clientID {
            return current
        }

        let saved: Credentials?
        if let data = loadKeychain(key: credentialsKey) {
            saved = try? JSONDecoder().decode(Credentials.self, from: data)
        } else if let refreshToken = loadKeychain(key: refreshTokenKey) {
            let accessToken = loadKeychain(key: accessTokenKey)
                .flatMap { String(data: $0, encoding: .utf8) }
            saved = Credentials(
                clientID: clientID, accessToken: accessToken ?? "",
                refreshToken: String(decoding: refreshToken, as: UTF8.self),
                expiresAt: loadDate(key: expiryDateKey) ?? .distantPast
            )
        } else {
            saved = nil
        }
        guard let saved, saved.clientID == clientID else { return nil }

        return credentialsLock.withLock {
            if let current = sessionCredentials, current.clientID == clientID {
                return current
            }
            sessionCredentials = saved
            return saved
        }
    }

    private func storeCredentials(_ credentials: Credentials) -> Bool {
        credentialsLock.withLock { sessionCredentials = credentials }
        guard let data = try? JSONEncoder().encode(credentials) else { return false }

        let item = keychainItem(credentialsKey)
        var entry = item
        entry[kSecValueData as String] = data
        let result = SecItemAdd(entry as CFDictionary, nil)
        if result == errSecDuplicateItem {
            let update = [kSecValueData as String: data] as CFDictionary
            return SecItemUpdate(item as CFDictionary, update) == errSecSuccess
        }
        return result == errSecSuccess
    }

    private func keychainItem(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
    }

    private func loadKeychain(key: String) -> Data? {
        var query = keychainItem(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        return status == errSecSuccess ? value as? Data : nil
    }

    private func loadDate(key: String) -> Date? {
        UserDefaults.standard.object(forKey: key) as? Date
    }
}

// MARK: - Utility Extensions

extension Data {
    func base64URLEncodedString() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Array where Element == UInt8 {
    static func random(count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255) }
    }
}
