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
    private var pendingAuthorization: (state: String, verifier: String)?

    @Published var didAuthenticate = false

    // MARK: - Public Interface

    static func authorizationScopes(likingEnabled: Bool) -> [String] {
        let queueScope = ["user-read-currently-playing"]
        return likingEnabled
            ? queueScope + ["user-library-read", "user-library-modify"]
            : queueScope
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
        guard !forceRefresh, let expiry = loadDate(key: expiryDateKey),
            expiry > Date(),
            let token = loadKeychain(key: accessTokenKey)
        else {
            refreshAccessToken(completion: completion)
            return
        }

        completion(token)
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

            self.saveKeychain(key: self.accessTokenKey, value: accessToken)
            self.saveKeychain(key: self.refreshTokenKey, value: refreshToken)
            self.saveDate(
                key: self.expiryDateKey,
                value: Date().addingTimeInterval(expiresIn)
            )

            DispatchQueue.main.async {
                self.didAuthenticate = true
            }
        }.resume()
    }

    private func refreshAccessToken(completion: @escaping (String?) -> Void) {
        guard let refreshToken = loadKeychain(key: refreshTokenKey),
            let clientID = clientID, !clientID.isEmpty
        else {
            completion(nil)
            return
        }

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"

        let bodyParams = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
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

            self.saveKeychain(key: self.accessTokenKey, value: accessToken)

            if let newRefreshToken = json["refresh_token"] as? String {
                self.saveKeychain(
                    key: self.refreshTokenKey,
                    value: newRefreshToken
                )
            }

            if let expiresIn = json["expires_in"] as? Double {
                self.saveDate(
                    key: self.expiryDateKey,
                    value: Date().addingTimeInterval(expiresIn)
                )
            }

            DispatchQueue.main.async {
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
    private func saveKeychain(key: String, value: String) {
        #if DEBUG
            UserDefaults.standard.set(value, forKey: "dev.\(key)")
        #else
            let data = Data(value.utf8)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: key,
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String:
                    kSecAttrAccessibleAfterFirstUnlock,
            ]
            let status = SecItemUpdate(
                query as CFDictionary, [kSecValueData as String: data] as CFDictionary
            )
            if status == errSecItemNotFound {
                SecItemAdd(
                    query.merging(attributes) { _, new in new } as CFDictionary, nil
                )
            }
        #endif
    }

    private func loadKeychain(key: String) -> String? {
        #if DEBUG
            return UserDefaults.standard.string(forKey: "dev.\(key)")
        #else
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            if status == errSecSuccess,
                let data = result as? Data,
                let string = String(data: data, encoding: .utf8)
            {
                return string
            } else {
                return nil
            }
        #endif
    }

    private func saveDate(key: String, value: Date) {
        UserDefaults.standard.set(value, forKey: key)
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
