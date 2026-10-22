import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct CodexTokens: Codable, Equatable {
    var access: String
    var refresh: String
    var expires: Date
    /// The client ID OpenAI issued to this installation at first sign-in.
    var clientID: String
    var subject: String
    var email: String?
    /// Kept for `id_token_hint` on the next sign-in.
    var idToken: String?
}

struct CodexAuthError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Official Sign in with ChatGPT for open-source apps: plan usage through OAuth with PKCE and a loopback callback.
/// See https://developers.openai.com/siwc/token-sharing-open-source/sign-in
enum CodexAuth {
    nonisolated static let issuer = "https://auth.openai.com"
    nonisolated static let authorizeEndpoint = issuer + "/api/accounts/authorize"
    nonisolated static let tokenEndpoint = issuer + "/api/accounts/oauth/token"
    nonisolated static let jwksEndpoint = issuer + "/.well-known/jwks.json"
    /// First sign-in registers with this client ID; OpenAI returns the issued one in the callback.
    nonisolated static let registrationClientID = "dynamic_agent_client"
    nonisolated static let agentName = "Third Hand"
    nonisolated static let resource = "https://api.openai.com/v1"
    nonisolated static let planScope = "chatgpt.tokens.use.direct"
    nonisolated static let scope = "openid profile email offline_access resource.invoke " + planScope
    nonisolated static let callbackPort: UInt16 = 1455
    nonisolated static let redirectURI = "http://127.0.0.1:1455/auth/callback"
    /// Refresh errors after which the stored tokens are useless.
    nonisolated static let terminalRefreshErrors: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired",
        "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]

    /// The client ID issued at first registration, reused for every later sign-in on this Mac.
    nonisolated static var issuedClientID: String? {
        get { UserDefaults.standard.string(forKey: "ChatGPTClientID") }
        set { UserDefaults.standard.set(newValue, forKey: "ChatGPTClientID") }
    }

    /// Stable per-Mac host identifier that OpenAI requires alongside the agent name.
    nonisolated static var hostID: String {
        if let id = UserDefaults.standard.string(forKey: "ChatGPTHostID") { return id }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "ChatGPTHostID")
        return id
    }

    struct PKCE {
        let verifier: String
        let challenge: String
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func base64URLDecode(_ text: Substring) -> Data? {
        var payload = String(text).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        return Data(base64Encoded: payload)
    }

    nonisolated static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    nonisolated static func makePKCE() -> PKCE {
        let verifier = base64URL(randomBytes(32))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return PKCE(verifier: verifier, challenge: challenge)
    }

    nonisolated static func authorizeURL(pkce: PKCE, state: String, nonce: String, clientID: String?,
                                         hostID: String, idTokenHint: String? = nil) -> URL {
        var components = URLComponents(string: authorizeEndpoint)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID ?? registrationClientID),
            URLQueryItem(name: "agent_name_hint", value: agentName),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce)
        ]
        if let idTokenHint { items.append(URLQueryItem(name: "id_token_hint", value: idTokenHint)) }
        components.queryItems = items
        // URLComponents leaves "+" unescaped, which query decoding reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Decodes a JWT segment without verifying it; `IDToken.verify` checks signatures.
    nonisolated static func claims(_ token: String?, segment: Int = 1) -> [String: Any] {
        let parts = token?.split(separator: ".", omittingEmptySubsequences: false) ?? []
        guard parts.count == 3, let data = base64URLDecode(parts[segment]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    /// `identity` is the verified ID token's claims, when the response carried one.
    /// The subject must stay the same across refreshes; a different account means signing in again.
    nonisolated static func normalize(_ raw: [String: Any], identity: [String: Any], clientID: String,
                                      previous: CodexTokens? = nil, now: Date = Date()) throws -> CodexTokens {
        let subject = identity["sub"] as? String ?? previous?.subject
        guard let subject, !subject.isEmpty, previous == nil || previous?.subject == subject else {
            throw CodexAuthError(message: "Sign in with ChatGPT again to confirm your account.")
        }
        guard let accessToken = raw["access_token"] as? String, !accessToken.isEmpty else {
            throw CodexAuthError(message: "ChatGPT did not return an access token. Sign in again.")
        }
        // A refresh may omit scope; it keeps what was granted at sign-in.
        if previous == nil || raw["scope"] != nil {
            let granted = (raw["scope"] as? String ?? "").split(separator: " ").map(String.init)
            guard granted.contains(planScope) else {
                throw CodexAuthError(message: "ChatGPT plan usage was not enabled for Third Hand. Sign in again and allow it, or check that your plan supports third-party apps.")
            }
        }
        guard let refresh = raw["refresh_token"] as? String ?? previous?.refresh else {
            throw CodexAuthError(message: "ChatGPT did not return a refresh token. Sign in again.")
        }
        let lifetime = (raw["expires_in"] as? Double) ?? 3600
        return CodexTokens(access: accessToken, refresh: refresh, expires: now.addingTimeInterval(lifetime),
                           clientID: clientID, subject: subject,
                           email: identity["email"] as? String ?? previous?.email,
                           idToken: raw["id_token"] as? String ?? previous?.idToken)
    }

    nonisolated static func tokenRequest(_ params: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: tokenEndpoint)!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" unescaped, which form decoding reads as a space.
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return request
    }

    /// `nonce` is checked for sign-in; refreshes carry none.
    nonisolated static func requestTokens(_ params: [String: String], clientID: String, nonce: String? = nil,
                                          previous: CodexTokens? = nil, session: URLSession,
                                          keys: IDToken.KeyProvider? = nil) async throws -> CodexTokens {
        let all = params.merging(["client_id": clientID, "resource": resource]) { a, _ in a }
        let (data, response) = try await session.data(for: tokenRequest(all))
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = raw["error"] as? String ?? ""
            Log.info("ChatGPT token error HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) code=\(code)")
            throw CodexRefreshError(terminal: terminalRefreshErrors.contains(code),
                                    message: "ChatGPT authorization expired or was declined. Sign in again.")
        }
        do {
            var identity: [String: Any] = [:]
            if let idToken = raw["id_token"] as? String {
                identity = try await IDToken.verify(idToken, clientID: clientID, nonce: nonce,
                                                    keys: keys ?? IDToken.remoteKeys(session: session))
            } else if previous == nil {
                throw CodexAuthError(message: "ChatGPT did not return an identity token. Sign in again.")
            }
            return try normalize(raw, identity: identity, clientID: clientID, previous: previous)
        } catch {
            // The server has already spent the old refresh token, so its replacement must survive the failure.
            if let previous, let refresh = raw["refresh_token"] as? String, !refresh.isEmpty, refresh != previous.refresh {
                throw CodexRotatedRefreshError(refresh: refresh, underlying: error)
            }
            throw error
        }
    }

    /// Opens the browser and waits for the loopback callback.
    @MainActor
    static func signIn(previous: CodexTokens? = nil, session: URLSession = .shared,
                       open: (URL) -> Void = { NSWorkspace.shared.open($0) }) async throws -> CodexTokens {
        let pkce = makePKCE()
        let state = base64URL(randomBytes(32))
        let nonce = base64URL(randomBytes(32))
        let server = CodexCallbackServer(state: state)
        try await server.start()
        defer { server.stop() }
        let known = issuedClientID
        open(authorizeURL(pkce: pkce, state: state, nonce: nonce, clientID: known, hostID: hostID,
                          idTokenHint: known != nil && previous?.clientID == known ? previous?.idToken : nil))
        let callback = try await AsyncTimeout.run(seconds: 300, message: "ChatGPT sign-in timed out. Try again.") {
            try await server.callback()
        }
        guard let clientID = callback.clientID ?? known else {
            throw CodexAuthError(message: "ChatGPT did not register Third Hand. Try signing in again.")
        }
        let tokens = try await requestTokens(["grant_type": "authorization_code", "code": callback.code,
                                              "redirect_uri": redirectURI, "code_verifier": pkce.verifier],
                                             clientID: clientID, nonce: nonce, session: session)
        issuedClientID = clientID
        return tokens
    }
}

/// A refresh succeeded at the server but its reply couldn't be used; `refresh` replaces the spent token.
struct CodexRotatedRefreshError: LocalizedError {
    let refresh: String
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

struct CodexRefreshError: LocalizedError {
    /// True when the refresh token can never work again and must be discarded.
    let terminal: Bool
    let message: String
    var errorDescription: String? { message }
}

/// Verifies OpenAI ID tokens: RS256 signature against the published JWKS, then issuer, audience, expiry and nonce.
enum IDToken {
    typealias KeyProvider = @Sendable (_ kid: String?) async throws -> SecKey

    nonisolated static func verify(_ token: String, clientID: String, nonce: String?, keys: KeyProvider,
                                   now: Date = Date()) async throws -> [String: Any] {
        let invalid = CodexAuthError(message: "ChatGPT returned an identity token Third Hand could not verify. Sign in again.")
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        let header = CodexAuth.claims(token, segment: 0)
        guard parts.count == 3, header["alg"] as? String == "RS256",
              let signature = CodexAuth.base64URLDecode(parts[2]) else { throw invalid }
        let key = try await keys(header["kid"] as? String)
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil) else {
            throw invalid
        }
        let claims = CodexAuth.claims(token)
        let audience = (claims["aud"] as? [String]) ?? [claims["aud"] as? String].compactMap { $0 }
        guard claims["iss"] as? String == CodexAuth.issuer, audience.contains(clientID),
              let exp = claims["exp"] as? Double, Date(timeIntervalSince1970: exp) > now.addingTimeInterval(-60),
              nonce == nil || claims["nonce"] as? String == nonce else { throw invalid }
        return claims
    }

    nonisolated static func remoteKeys(session: URLSession) -> KeyProvider {
        { kid in
            let (data, _) = try await session.data(from: URL(string: CodexAuth.jwksEndpoint)!)
            let keys = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["keys"] as? [[String: Any]] ?? []
            guard let jwk = keys.first(where: { kid == nil || $0["kid"] as? String == kid }),
                  let key = rsaKey(jwk) else {
                throw CodexAuthError(message: "Could not load ChatGPT's signing keys. Try again.")
            }
            return key
        }
    }

    /// Builds an RSA public key from a JWK's modulus and exponent (PKCS#1 RSAPublicKey DER).
    nonisolated static func rsaKey(_ jwk: [String: Any]) -> SecKey? {
        guard jwk["kty"] as? String == "RSA",
              let n = (jwk["n"] as? String).flatMap({ CodexAuth.base64URLDecode(Substring($0)) }),
              let e = (jwk["e"] as? String).flatMap({ CodexAuth.base64URLDecode(Substring($0)) }) else { return nil }
        func length(_ count: Int) -> [UInt8] {
            if count < 0x80 { return [UInt8(count)] }
            let bytes = withUnsafeBytes(of: UInt32(count).bigEndian, Array.init).drop { $0 == 0 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ value: Data) -> [UInt8] {
            var bytes = Array(value.drop { $0 == 0 })
            if bytes.isEmpty || bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return [0x02] + length(bytes.count) + bytes
        }
        let body = integer(n) + integer(e)
        let der = Data([0x30] + length(body.count) + body)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }
}

/// Serializes token refresh so concurrent requests never spend the same refresh token twice.
actor CodexCredentials {
    private var tokens: CodexTokens
    private var refreshing: Task<CodexTokens, Error>?
    private let session: URLSession
    private let persist: @Sendable (CodexTokens) throws -> Void
    private let forget: @Sendable () -> Void
    private let keys: IDToken.KeyProvider?

    init(tokens: CodexTokens, session: URLSession = .shared,
         persist: @escaping @Sendable (CodexTokens) throws -> Void = { try KeychainHelper.saveCodexTokens($0) },
         forget: @escaping @Sendable () -> Void = { KeychainHelper.deleteCodexTokens() },
         keys: IDToken.KeyProvider? = nil) {
        self.tokens = tokens
        self.session = session
        self.persist = persist
        self.forget = forget
        self.keys = keys
    }

    func current(now: Date = Date()) async throws -> CodexTokens {
        if tokens.expires > now.addingTimeInterval(60) { return tokens }
        if let refreshing { return try await refreshing.value }
        let previous = tokens
        let session = session
        let keys = keys
        let task = Task {
            try await CodexAuth.requestTokens(["grant_type": "refresh_token", "refresh_token": previous.refresh],
                                              clientID: previous.clientID, previous: previous, session: session, keys: keys)
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            tokens = fresh
            save(fresh)
            Log.info("ChatGPT token refreshed")
            return fresh
        } catch let error as CodexRotatedRefreshError {
            // Keep the expired access token so the next request refreshes again with the new refresh token.
            tokens.refresh = error.refresh
            save(tokens)
            Log.info("ChatGPT token refresh unusable; kept the rotated refresh token")
            throw error.underlying
        } catch let error as CodexRefreshError where error.terminal {
            forget()
            throw error
        }
    }

    /// The tokens in memory stay valid for this session even when Keychain can't store them.
    private func save(_ tokens: CodexTokens) {
        do { try persist(tokens) }
        catch { Log.info("ChatGPT token save failed error_type=\(String(reflecting: type(of: error)))") }
    }
}

/// A new registration also returns the issued client ID.
struct OAuthCallback: Equatable {
    let code: String
    let clientID: String?
}

/// Minimal loopback HTTP listener for the OAuth redirect.
final class CodexCallbackServer: @unchecked Sendable {
    private let state: String
    private let queue = DispatchQueue(label: "thirdhand.codex-callback")
    private var listener: NWListener?
    private var result: Result<OAuthCallback, Error>?
    private var waiter: CheckedContinuation<OAuthCallback, Error>?
    private var starting: CheckedContinuation<Void, Error>?

    init(state: String) { self.state = state }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: CodexAuth.callbackPort)!) }
        catch { throw CodexAuthError(message: "Port \(CodexAuth.callbackPort) is unavailable. Close other ChatGPT sign-in windows and try again.") }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        // State updates arrive on `queue`, which also owns `starting`.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.starting = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, let starting = self.starting else { return }
                    switch state {
                    case .ready: self.starting = nil; starting.resume()
                    case .failed, .cancelled:
                        self.starting = nil
                        starting.resume(throwing: CodexAuthError(message: "Port \(CodexAuth.callbackPort) is unavailable. Close other ChatGPT sign-in windows and try again."))
                    default: break
                    }
                }
                listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.finish(.failure(CancellationError()))
        }
    }

    func callback() async throws -> OAuthCallback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result { continuation.resume(with: result) }
                    else { self.waiter = continuation }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ outcome: Result<OAuthCallback, Error>) {
        guard result == nil else { return }
        result = outcome
        waiter?.resume(with: outcome)
        waiter = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let (status, message, outcome) = Self.evaluate(request: request, state: self.state)
            if let outcome { self.finish(outcome) }
            let html = "<!doctype html><meta charset=utf-8><title>Third Hand</title><body style=\"font:15px -apple-system;padding:40px\">\(message)</body>"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// Returns the HTTP status, page text, and sign-in outcome (nil for unrelated requests).
    static func evaluate(request: String, state: String) -> (String, String, Result<OAuthCallback, Error>?) {
        let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard let components = URLComponents(string: "http://localhost" + target), components.path == "/auth/callback" else {
            return ("404 Not Found", "Not found.", nil)
        }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
        if let error = items["error"] {
            let detail = items["error_description"] ?? error
            return ("200 OK", "Sign-in failed. You can close this tab.", .failure(CodexAuthError(message: "ChatGPT sign-in failed: \(detail.prefix(200))")))
        }
        guard items["state"] == state else {
            return ("400 Bad Request", "Sign-in could not be verified. Start again from Third Hand.",
                    .failure(CodexAuthError(message: "ChatGPT sign-in could not be verified. Try again.")))
        }
        guard let code = items["code"], !code.isEmpty else {
            return ("400 Bad Request", "Sign-in failed. Start again from Third Hand.",
                    .failure(CodexAuthError(message: "ChatGPT did not return an authorization code.")))
        }
        return ("200 OK", "Signed in to Third Hand. You can close this tab.", .success(OAuthCallback(code: code, clientID: items["client_id"].flatMap { $0.isEmpty ? nil : $0 })))
    }
}
