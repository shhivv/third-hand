import CryptoKit
import XCTest
@testable import ThirdHand

private func jwt(_ claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    return "e30." + CodexAuth.base64URL(payload) + ".sig"
}

/// A throwaway RSA key standing in for OpenAI's signing key.
private let signingKey: SecKey = {
    let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
    return SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
}()
private let testKeys: IDToken.KeyProvider = { _ in SecKeyCopyPublicKey(signingKey)! }

private func signedJWT(_ claims: [String: Any], key: SecKey = signingKey) -> String {
    let header = CodexAuth.base64URL(try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "k1"]))
    let input = header + "." + CodexAuth.base64URL(try! JSONSerialization.data(withJSONObject: claims))
    let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)! as Data
    return input + "." + CodexAuth.base64URL(signature)
}

private func idClaims(subject: String = "user_1", nonce: String? = "n1", audience: String = "client_1") -> [String: Any] {
    var claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": audience, "sub": subject, "email": "a@example.com",
                                 "exp": Date().addingTimeInterval(3600).timeIntervalSince1970]
    if let nonce { claims["nonce"] = nonce }
    return claims
}

private func tokenResponse(subject: String = "user_1", refresh: String? = "refresh_2", nonce: String? = "n1",
                           scope: String? = CodexAuth.scope) -> [String: Any] {
    var raw: [String: Any] = [
        "access_token": jwt(["sub": subject]),
        "id_token": signedJWT(idClaims(subject: subject, nonce: nonce)),
        "expires_in": 3600.0
    ]
    if let refresh { raw["refresh_token"] = refresh }
    if let scope { raw["scope"] = scope }
    return raw
}

private func body(of request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

/// Serves canned responses; records every request.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        captured.httpBody = body(of: request)
        Self.requests.append(captured)
        let (status, data) = Self.handler!(captured)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session(_ handler: @escaping (URLRequest) -> (Int, Data)) -> URLSession {
        self.handler = handler
        requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

private func sse(_ events: [[String: Any]]) -> Data {
    Data(events.map { "event: \($0["type"]!)\ndata: " + String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined().utf8)
}

private let fixtureTokens = CodexTokens(access: "access_1", refresh: "refresh_1", expires: Date().addingTimeInterval(3600),
                                        clientID: "client_1", subject: "user_1", email: nil)

@MainActor
final class CodexAuthTests: XCTestCase {
    func testAuthorizeURLFollowsOfficialRegistrationFlow() throws {
        let pkce = CodexAuth.makePKCE()
        XCTAssertEqual(pkce.verifier.count, 43)
        XCTAssertEqual(pkce.challenge, CodexAuth.base64URL(Data(SHA256.hash(data: Data(pkce.verifier.utf8)))))
        let url = CodexAuth.authorizeURL(pkce: pkce, state: "state_1", nonce: "n1", clientID: nil, hostID: "urn:uuid:h1")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(url.absoluteString.components(separatedBy: "?")[0], "https://auth.openai.com/api/accounts/authorize")
        XCTAssertEqual(items["client_id"], "dynamic_agent_client", "First sign-in registers dynamically")
        XCTAssertEqual(items["agent_name_hint"], "Third Hand")
        XCTAssertEqual(items["ext_agent_host_id"], "urn:uuid:h1")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(items["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        XCTAssertEqual(items["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "state_1")
        XCTAssertEqual(items["nonce"], "n1")
        XCTAssertNil(items["id_token_hint"])
        let again = CodexAuth.authorizeURL(pkce: pkce, state: "s", nonce: "n", clientID: "client_1", hostID: "urn:uuid:h1", idTokenHint: "hint")
        let later = Dictionary(uniqueKeysWithValues: URLComponents(url: again, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(later["client_id"], "client_1", "Later sign-ins reuse the issued client ID")
        XCTAssertEqual(later["id_token_hint"], "hint")
    }

    func testIDTokenMustBeSignedForThisClientAndNonce() async throws {
        let claims = try await IDToken.verify(signedJWT(idClaims()), clientID: "client_1", nonce: "n1", keys: testKeys)
        XCTAssertEqual(claims["sub"] as? String, "user_1")
        let other = SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048] as CFDictionary, nil)!
        for (token, nonce) in [(signedJWT(idClaims(), key: other), "n1"),                  // forged signature
                               (signedJWT(idClaims(audience: "someone_else")), "n1"),   // wrong audience
                               (signedJWT(idClaims()), "n2"),                           // replayed nonce
                               (jwt(idClaims()), "n1")] {                               // unsigned
            do { _ = try await IDToken.verify(token, clientID: "client_1", nonce: nonce, keys: testKeys); XCTFail("Accepted a bad ID token") }
            catch {}
        }
    }

    func testJWKBecomesVerifyingKey() throws {
        // PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }.
        let der = [UInt8](SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(signingKey)!, nil)! as Data)
        var index = 1
        func length() -> Int {
            let first = Int(der[index]); index += 1
            guard first & 0x80 != 0 else { return first }
            var value = 0
            for _ in 0..<(first & 0x7f) { value = value << 8 | Int(der[index]); index += 1 }
            return value
        }
        _ = length()
        func integer() -> Data { index += 1; let count = length(); defer { index += count }; return Data(der[index..<index + count]) }
        let (n, e) = (integer(), integer())
        let key = try XCTUnwrap(IDToken.rsaKey(["kty": "RSA", "n": CodexAuth.base64URL(n), "e": CodexAuth.base64URL(e)]))
        let message = Data("hello".utf8)
        let signature = SecKeyCreateSignature(signingKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)! as Data
        XCTAssertTrue(SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil))
    }

    func testTokensRequirePlanScopeAndRejectAccountSwitchOnRefresh() throws {
        let identity = idClaims()
        let first = try CodexAuth.normalize(tokenResponse(), identity: identity, clientID: "client_1")
        XCTAssertEqual(first.clientID, "client_1")
        XCTAssertEqual(first.subject, "user_1")
        XCTAssertEqual(first.email, "a@example.com")
        XCTAssertNotNil(first.idToken)
        let refreshed = try CodexAuth.normalize(tokenResponse(refresh: nil, scope: nil), identity: [:], clientID: "client_1", previous: first)
        XCTAssertEqual(refreshed.refresh, "refresh_2", "A refresh without a new token keeps the previous one")
        XCTAssertThrowsError(try CodexAuth.normalize(tokenResponse(), identity: idClaims(subject: "user_2"), clientID: "client_1", previous: first))
        XCTAssertThrowsError(try CodexAuth.normalize(tokenResponse(scope: "openid profile email offline_access"), identity: identity, clientID: "client_1"),
                             "Sign-in without plan usage is rejected")
        XCTAssertThrowsError(try CodexAuth.normalize(["access_token": "opaque", "scope": CodexAuth.scope], identity: [:], clientID: "client_1"))
    }

    func testTokenRequestIsFormEncoded() {
        let request = CodexAuth.tokenRequest(["grant_type": "refresh_token", "refresh_token": "a+b/c="])
        XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/api/accounts/oauth/token")
        let form = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("refresh_token=a%2Bb/c%3D") || form.contains("refresh_token=a%2Bb%2Fc%3D"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    }

    func testCallbackRequiresMatchingState() {
        let ok = CodexCallbackServer.evaluate(request: "GET /auth/callback?code=abc&state=s1 HTTP/1.1\r\nHost: localhost\r\n\r\n", state: "s1")
        XCTAssertEqual(try ok.2?.get(), OAuthCallback(code: "abc", clientID: nil))
        let registered = CodexCallbackServer.evaluate(request: "GET /auth/callback?code=abc&state=s1&client_id=client_9 HTTP/1.1\r\n\r\n", state: "s1")
        XCTAssertEqual(try registered.2?.get().clientID, "client_9", "A new registration returns the issued client ID")
        let forged = CodexCallbackServer.evaluate(request: "GET /auth/callback?code=abc&state=other HTTP/1.1\r\n\r\n", state: "s1")
        XCTAssertThrowsError(try forged.2!.get())
        let denied = CodexCallbackServer.evaluate(request: "GET /auth/callback?error=access_denied&state=s1 HTTP/1.1\r\n\r\n", state: "s1")
        XCTAssertThrowsError(try denied.2!.get())
        XCTAssertNil(CodexCallbackServer.evaluate(request: "GET /favicon.ico HTTP/1.1\r\n\r\n", state: "s1").2)
    }

    func testLoopbackServerReceivesBrowserRedirect() async throws {
        let server = CodexCallbackServer(state: "s1")
        try await server.start()
        defer { server.stop() }
        let (_, favicon) = try await URLSession.shared.data(from: URL(string: "http://localhost:1455/favicon.ico")!)
        XCTAssertEqual((favicon as? HTTPURLResponse)?.statusCode, 404)
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:1455/auth/callback?code=abc&state=s1")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let callback = try await server.callback()
        XCTAssertEqual(callback.code, "abc")
    }

    func testConcurrentRequestsShareOneRefresh() async throws {
        let session = StubProtocol.session { _ in (200, try! JSONSerialization.data(withJSONObject: tokenResponse(nonce: nil))) }
        var expired = fixtureTokens
        expired.expires = Date().addingTimeInterval(-10)
        let saved = SavedTokens()
        let credentials = CodexCredentials(tokens: expired, session: session, persist: { saved.value = $0 }, keys: testKeys)
        async let a = credentials.current()
        async let b = credentials.current()
        let (first, second) = try await (a, b)
        XCTAssertEqual(first, second)
        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(saved.value?.refresh, "refresh_2")
        let form = String(decoding: StubProtocol.requests[0].httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("grant_type=refresh_token"))
        XCTAssertTrue(form.contains("refresh_token=refresh_1"))
        XCTAssertTrue(form.contains("client_id=client_1"))
        XCTAssertTrue(form.contains("resource=https"))
    }

    func testRevokedRefreshTokenIsForgotten() async throws {
        let session = StubProtocol.session { _ in (400, Data(#"{"error":"refresh_token_reused"}"#.utf8)) }
        var expired = fixtureTokens
        expired.expires = Date().addingTimeInterval(-10)
        let forgotten = SavedTokens()
        let revoked = expired
        let credentials = CodexCredentials(tokens: expired, session: session, persist: { _ in },
                                           forget: { forgotten.value = revoked }, keys: testKeys)
        do { _ = try await credentials.current(); XCTFail("Expected a refresh failure") }
        catch let error as CodexRefreshError { XCTAssertTrue(error.terminal) }
        XCTAssertNotNil(forgotten.value)
    }

    func testRotatedRefreshTokenSurvivesAnUnusableReply() async throws {
        // The server spends refresh_1 and returns refresh_2, but the reply has no access token.
        let session = StubProtocol.session { _ in (200, Data(#"{"refresh_token":"refresh_2"}"#.utf8)) }
        var expired = fixtureTokens
        expired.expires = Date().addingTimeInterval(-10)
        let saved = SavedTokens()
        let credentials = CodexCredentials(tokens: expired, session: session, persist: { saved.value = $0 },
                                           forget: { XCTFail("A rotated token must not be forgotten") }, keys: testKeys)
        do { _ = try await credentials.current(); XCTFail("Expected a refresh failure") }
        catch { XCTAssertFalse(error is CodexRotatedRefreshError, "The underlying error is reported") }
        XCTAssertEqual(saved.value?.refresh, "refresh_2")
        _ = try? await credentials.current()
        let form = String(decoding: StubProtocol.requests.last!.httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("refresh_token=refresh_2"))
    }

    func testFailedKeychainSaveStillReturnsRefreshedTokens() async throws {
        let session = StubProtocol.session { _ in (200, try! JSONSerialization.data(withJSONObject: tokenResponse(nonce: nil))) }
        var expired = fixtureTokens
        expired.expires = Date().addingTimeInterval(-10)
        let credentials = CodexCredentials(tokens: expired, session: session,
                                           persist: { _ in throw CodexAuthError(message: "keychain") }, keys: testKeys)
        let fresh = try await credentials.current()
        XCTAssertEqual(fresh.refresh, "refresh_2")
    }
}

private final class SavedTokens: @unchecked Sendable { var value: CodexTokens? }

@MainActor
final class CodexClientTests: XCTestCase {
    func testStreamedFunctionCallAndRequestShape() async throws {
        let call: [String: Any] = ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "step",
                                   "arguments": #"{"instruction":"Type in the search field","text":"adele"}"#]
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_1", "encrypted_content": "opaque", "summary": []]
        let session = StubProtocol.session { _ in (200, sse([
            ["type": "response.created", "response": ["id": "resp_1"]],
            ["type": "response.output_item.done", "item": reasoning],
            ["type": "response.output_item.done", "item": call],
            ["type": "response.completed", "response": ["id": "resp_1", "output": [reasoning, call]]]
        ])) }
        let client = CodexClient(credentials: CodexCredentials(tokens: fixtureTokens), session: session)
        let response = try await client.respond(model: "gpt-test", instructions: "Be helpful", input: [CodexAgent.userMessage("hi")], tools: CodexAgent.tools)
        XCTAssertEqual(response.functionCalls, [CodexFunctionCall(callID: "call_1", name: "step", arguments: call["arguments"] as! String)])
        XCTAssertEqual(response.output.count, 2, "Reasoning items are kept for the next turn")

        let request = StubProtocol.requests[0]
        XCTAssertEqual(request.url, CodexClient.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access_1")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertFalse((request.value(forHTTPHeaderField: "User-Agent") ?? "").contains("opencode"))
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "gpt-test")
        XCTAssertEqual(json["instructions"] as? String, "Be helpful")
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(json["include"] as? [String], ["reasoning.encrypted_content"])
    }

    func testFailedStreamAndHTTPErrorsSendNoAction() async throws {
        let failing = StubProtocol.session { _ in (200, sse([["type": "response.failed", "response": ["error": ["message": "boom"]]]])) }
        do {
            _ = try await CodexClient(credentials: CodexCredentials(tokens: fixtureTokens), session: failing)
                .respond(model: "gpt-test", instructions: "x", input: [], tools: [])
            XCTFail("A failed stream must not produce calls")
        } catch let error as CodexServiceError { XCTAssertEqual(error.status, 502) }

        let expired = StubProtocol.session { _ in (401, Data(#"{"detail":"Unauthorized"}"#.utf8)) }
        do {
            _ = try await CodexClient(credentials: CodexCredentials(tokens: fixtureTokens), session: expired)
                .respond(model: "gpt-test", instructions: "x", input: [], tools: [])
            XCTFail("Expected an auth error")
        } catch let error as CodexServiceError {
            XCTAssertEqual(error.status, 401)
            XCTAssertTrue(error.message.contains("Sign in again"))
        }
    }

    func testPlanUsageErrorsExplainWhatToDo() async throws {
        let limited = StubProtocol.session { _ in (429, Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"cap"}}"#.utf8)) }
        do {
            _ = try await CodexClient(credentials: CodexCredentials(tokens: fixtureTokens), session: limited)
                .respond(model: "gpt-test", instructions: "x", input: [], tools: [])
            XCTFail("Expected a limit error")
        } catch let error as CodexServiceError { XCTAssertTrue(error.message.contains("Settings → Usage")) }
        let failed = sse([["type": "response.failed", "response": ["error": ["code": "subscription_sharing_user_not_eligible"]]]])
        XCTAssertThrowsError(try CodexClient.collect(failed.split(separator: UInt8(ascii: "\n")).compactMap {
            CodexClient.event(fromLine: String(decoding: $0, as: UTF8.self)) })) {
            XCTAssertTrue(($0 as? CodexServiceError)?.message.contains("third-party apps") == true)
        }
    }

    func testModelListKeepsListedSlugs() async throws {
        let session = StubProtocol.session { _ in (200, Data(#"{"models":[{"slug":"gpt-6.1-sol","visibility":"list"},{"slug":"hidden","visibility":"hide"}]}"#.utf8)) }
        let models = try await CodexClient(credentials: CodexCredentials(tokens: fixtureTokens), session: session).availableModels()
        XCTAssertEqual(models, ["gpt-6.1-sol"])
        XCTAssertEqual(StubProtocol.requests[0].url?.absoluteString, "https://api.openai.com/v1/models")
    }

    func testSSELineParsingIgnoresNonDataLines() {
        XCTAssertNil(CodexClient.event(fromLine: "event: response.completed"))
        XCTAssertNil(CodexClient.event(fromLine: "data: [DONE]"))
        XCTAssertEqual(CodexClient.event(fromLine: #"data: {"type":"x"}"#)?["type"] as? String, "x")
    }
}

@MainActor
private final class ScriptedPlanner: Planner {
    var turns: [[[String: Any]]]
    var inputs: [[[String: Any]]] = []
    var models: [String] = []
    init(_ turns: [[[String: Any]]]) { self.turns = turns }
    func respond(model: String, instructions: String, input: [[String: Any]], tools: [[String: Any]], effort: String) async throws -> CodexResponse {
        inputs.append(input)
        models.append(model + "/" + effort)
        return CodexResponse(output: turns.isEmpty ? [] : turns.removeFirst())
    }
}

@MainActor
private final class RecordingLayer: ActionLayer {
    var steps: [(String, String?)] = []
    /// Status per performed step; defaults to verified.
    var statuses: [String] = []
    func currentElements() async throws -> [AccessibilityElement] {
        [AccessibilityElement(id: 1, role: "AXTextField", label: "Search", value: nil, enabled: true, actions: [], axElement: nil)]
    }
    func perform(step: PlanStep) async throws -> StepOutcome {
        steps.append((step.target ?? step.key ?? step.action, step.text))
        let status = statuses.isEmpty ? "verified" : statuses.removeFirst()
        return StepOutcome(status: status, detail: "ok", elements: [
            AccessibilityElement(id: 1, role: "AXTextField", label: "Search", value: "screen \(steps.count)", enabled: true, actions: [], axElement: nil)
        ])
    }
}

private func call(_ id: String, _ name: String, _ args: [String: Any?]) -> [String: Any] {
    let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: args.mapValues { $0 ?? NSNull() }), as: UTF8.self)
    return ["type": "function_call", "call_id": id, "name": name, "arguments": arguments]
}

private func act(_ id: String, _ steps: [(String, String?)], summary: String?) -> [String: Any] {
    // ("Press Return", nil) is a press step, (label, text) a type step, and (label, nil) a click step.
    func step(_ label: String, _ text: String?) -> [String: Any] {
        var step: [String: Any] = ["action": "click", "target": label, "role": NSNull(), "near": NSNull(), "text": NSNull(), "key": NSNull(), "direction": NSNull()]
        if label.hasPrefix("Press ") {
            step["action"] = "press"; step["target"] = NSNull(); step["key"] = String(label.dropFirst(6)).lowercased()
        } else if let text {
            step["action"] = "type"; step["text"] = text
        }
        return step
    }
    return call(id, "act", ["steps": steps.map { step($0.0, $0.1) },
                     "finishes_task": summary != nil, "summary": summary ?? "Check the results."])
}

private let fast = PlannerTier(model: "gpt-6-sol", effort: "none")

@MainActor
final class CodexAgentTests: XCTestCase {
    func testFailedPlanEscalatesEffortAndKeepsSameModelReasoning() async throws {
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_1", "encrypted_content": "sol"]
        let planner = ScriptedPlanner([
            [reasoning, act("c1", [("Click Search", nil)], summary: "Searched.")],
            [call("c2", "done", ["summary": "ok"])]
        ])
        let layer = RecordingLayer()
        layer.statuses = ["blocked"]
        let outcome = try await CodexAgent(planner: planner, tier: fast, escalation: .strong).run(goal: "g", appName: "App", layer: layer)
        XCTAssertEqual(outcome, .done("ok"))
        XCTAssertEqual(planner.models, ["gpt-6-sol/none", "gpt-6-sol/low"])
        XCTAssertTrue(planner.inputs[1].contains { $0["type"] as? String == "reasoning" }, "Same-model reasoning is kept")
        XCTAssertEqual(planner.inputs[1].filter { $0["type"] as? String == "function_call_output" }.count, 1)
    }

    func testSwitchingModelsDropsForeignReasoning() async throws {
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_1", "encrypted_content": "other-model"]
        let planner = ScriptedPlanner([
            [reasoning, act("c1", [("Click Search", nil)], summary: "Searched.")],
            [call("c2", "done", ["summary": "ok"])]
        ])
        let layer = RecordingLayer()
        layer.statuses = ["blocked"]
        _ = try await CodexAgent(planner: planner, tier: PlannerTier(model: "gpt-other", effort: "none"), escalation: .strong)
            .run(goal: "g", appName: "App", layer: layer)
        XCTAssertEqual(planner.models, ["gpt-other/none", "gpt-6-sol/low"])
        XCTAssertFalse(planner.inputs[1].contains { $0["type"] as? String == "reasoning" })
    }

    func testSuccessfulPlanNeverEscalates() async throws {
        let planner = ScriptedPlanner([[act("c1", [("Click Search", nil)], summary: "Done.")]])
        _ = try await CodexAgent(planner: planner, tier: fast, escalation: .strong).run(goal: "g", appName: "App", layer: RecordingLayer())
        XCTAssertEqual(planner.models, ["gpt-6-sol/none"])
    }

    func testWholeTaskRunsFromOnePlannerTurn() async throws {
        let planner = ScriptedPlanner([[act("c1", [("Click the Search field", nil),
                                                   ("Type into the search field", "Adele — Skyfall (2012)"),
                                                   ("Press Return", nil)], summary: "Searched for Skyfall.")]])
        let layer = RecordingLayer()
        let outcome = try await CodexAgent(planner: planner, tier: fast).run(goal: "search skyfall", appName: "Spotify", layer: layer)
        XCTAssertEqual(outcome, .done("Searched for Skyfall."))
        XCTAssertEqual(planner.inputs.count, 1)
        XCTAssertEqual(layer.steps.map(\.0), ["Click the Search field", "Type into the search field", "return"])
        XCTAssertEqual(layer.steps[1].1, "Adele — Skyfall (2012)", "Planner text is typed verbatim")
        XCTAssertNil(layer.steps[2].1)
    }

    func testFailedStepStopsPlanAndReturnsScreenToPlanner() async throws {
        let planner = ScriptedPlanner([
            [act("c1", [("Click Search", nil), ("Type query", "adele"), ("Press Return", nil)], summary: "Searched.")],
            [call("c2", "fail", ["reason": "No search field."])]
        ])
        let layer = RecordingLayer()
        layer.statuses = ["verified", "blocked"]
        let outcome = try await CodexAgent(planner: planner, tier: fast).run(goal: "g", appName: "App", layer: layer)
        XCTAssertEqual(outcome, .failed("No search field."))
        XCTAssertEqual(layer.steps.count, 2, "Steps after a failure are not run")
        let output = try XCTUnwrap(planner.inputs[1].last?["output"] as? String)
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        XCTAssertEqual(result["completed_all_steps"] as? Bool, false)
        XCTAssertTrue((result["screen"] as? String)?.contains("screen 2") == true)
        XCTAssertTrue(output.contains("not_run"))
    }

    func testTerminalInputSentCountsAsProgress() async throws {
        let planner = ScriptedPlanner([[act("c1", [("Type the command", "ls -la"), ("Press Return", nil)], summary: "Listed files.")]])
        let layer = RecordingLayer()
        layer.statuses = ["sent", "verified"]
        let outcome = try await CodexAgent(planner: planner, tier: fast).run(goal: "list files", appName: "Terminal", layer: layer)
        XCTAssertEqual(outcome, .done("Listed files."))
    }

    func testNullSummaryReturnsScreenAndOnlyNewestScreenIsFull() async throws {
        let planner = ScriptedPlanner([
            [act("c1", [("Click Search", nil)], summary: nil)],
            [act("c2", [("Click Search again", nil)], summary: nil)],
            [call("c3", "done", ["summary": "ok"])]
        ])
        _ = try await CodexAgent(planner: planner, tier: fast).run(goal: "g", appName: "App", layer: RecordingLayer())
        let last = planner.inputs[2]
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: last), as: UTF8.self)
        XCTAssertFalse(serialized.contains("Current screen"), "The opening screen is compacted after a step")
        XCTAssertFalse(serialized.contains("screen 1"), "Older step screens are compacted")
        XCTAssertTrue(serialized.contains("screen 2"))
        let outputs = last.filter { $0["type"] as? String == "function_call_output" }.map { $0["call_id"] as? String }
        XCTAssertEqual(outputs, ["c1", "c2"])
    }

    func testEveryExtraCallGetsAnOutputAndIsNotExecuted() async throws {
        let planner = ScriptedPlanner([
            [act("c1", [("Click A", nil)], summary: nil), act("c2", [("Click B", nil)], summary: nil)],
            [call("c3", "fail", ["reason": "Needs sign-in."])]
        ])
        let layer = RecordingLayer()
        let outcome = try await CodexAgent(planner: planner, tier: fast).run(goal: "g", appName: "App", layer: layer)
        XCTAssertEqual(outcome, .failed("Needs sign-in."))
        XCTAssertEqual(layer.steps.map(\.0), ["Click A"])
        let outputs = planner.inputs[1].filter { $0["type"] as? String == "function_call_output" }.map { $0["call_id"] as? String }
        XCTAssertEqual(outputs, ["c1", "c2"])
    }

    func testPlannerThatNeverCallsAToolStopsAfterOneNudge() async throws {
        let message: [String: Any] = ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "I can't do that."]]]
        let planner = ScriptedPlanner([[message], [message]])
        let layer = RecordingLayer()
        let outcome = try await CodexAgent(planner: planner, tier: fast).run(goal: "g", appName: "App", layer: layer)
        XCTAssertEqual(outcome, .failed("I can't do that."))
        XCTAssertEqual(planner.inputs.count, 2)
        XCTAssertTrue(layer.steps.isEmpty)
    }

    func testInvalidPlanIsRejectedBeforeAnyInput() async throws {
        let planner = ScriptedPlanner([
            [act("c1", [("Click A", nil), ("  ", nil)], summary: "x")],
            [call("c2", "done", ["summary": "ok"])]
        ])
        let layer = RecordingLayer()
        _ = try await CodexAgent(planner: planner, tier: fast).run(goal: "g", appName: "App", layer: layer)
        XCTAssertTrue(layer.steps.isEmpty, "A plan with any invalid step sends no input")
        let output = planner.inputs[1].last?["output"] as? String
        XCTAssertTrue(output?.contains("rejected") == true)
    }

    func testActToolRequiresExplicitFinishDecision() throws {
        let act = CodexAgent.tools.first { $0["name"] as? String == "act" }!
        let parameters = act["parameters"] as! [String: Any]
        XCTAssertEqual(parameters["required"] as? [String], ["finishes_task", "summary", "steps"])
        XCTAssertEqual(act["strict"] as? Bool, true)
    }
}

@MainActor
final class PlannerEffortTests: XCTestCase {
    func testRejectedEffortRetriesWithLow() async throws {
        let done = sse([["type": "response.completed", "response": ["output": [
            ["type": "function_call", "call_id": "c", "name": "done", "arguments": #"{"summary":"ok"}"#]]]]])
        let session = StubProtocol.session { request in
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let effort = (body["reasoning"] as! [String: Any])["effort"] as! String
            return effort == "minimal" ? (400, Data(#"{"error":{"message":"Unsupported value: minimal"}}"#.utf8)) : (200, done)
        }
        let client = CodexClient(credentials: CodexCredentials(tokens: fixtureTokens), session: session)
        let response = try await client.respond(model: "gpt-6-sol", instructions: "x", input: [], tools: [], effort: "minimal")
        XCTAssertEqual(response.functionCalls.first?.name, "done")
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }
}

@MainActor
final class PlanValidationTests: XCTestCase {
    func testPlanNamesTheFailingStep() {
        let args: [String: Any] = ["steps": [["action": "click", "target": "Play"], ["action": "type", "target": "Search"]]]
        guard case .failure(let error) = CodexAgent.plan(from: args) else { return XCTFail("Missing text must reject the plan") }
        XCTAssertTrue(error.localizedDescription.hasPrefix("Step 2:"))
    }

    func testScreenKeepsControlsAndEvidenceButBoundsOtherText() {
        func el(_ id: Int, _ role: String, _ label: String?, focused: Bool = false) -> AccessibilityElement {
            AccessibilityElement(id: id, role: role, label: label, value: nil, enabled: true, actions: [], axElement: nil, focused: focused)
        }
        var elements = [el(1, "AXButton", "Play"), el(2, "AXButton", nil), el(3, "AXTextField", "Search", focused: true),
                        el(4, "AXGroup", "Now playing: Skyfall"), el(5, "AXButton", "Play")]
        elements += (100..<200).map { el($0, "AXStaticText", "Caption \($0)") }
        elements.append(el(900, "AXRow", "Nights · Song"))
        let screen = CodexAgent.describe(elements)
        XCTAssertEqual(screen.components(separatedBy: "button \"Play\"").count - 1, 1, "Exact duplicates collapse")
        XCTAssertFalse(screen.contains("(unlabeled)"))
        XCTAssertTrue(screen.contains("textField \"Search\" [focused]"))
        XCTAssertTrue(screen.contains("Now playing: Skyfall"))
        XCTAssertTrue(screen.contains("row \"Nights · Song\""), "Controls after the text budget are still listed")
        XCTAssertEqual(screen.components(separatedBy: "staticText").count - 1, CodexAgent.maxContextLines)
        XCTAssertTrue(screen.contains("60 more non-interactive elements omitted"))
    }

    func testStepSchemaFixesTheActionSet() throws {
        let act = CodexAgent.tools.first { $0["name"] as? String == "act" }!
        let steps = (act["parameters"] as! [String: Any])["properties"] as! [String: Any]
        let item = (steps["steps"] as! [String: Any])["items"] as! [String: Any]
        XCTAssertEqual(item["required"] as? [String], ["action", "target", "role", "near", "text", "key", "direction"])
        let action = (item["properties"] as! [String: Any])["action"] as! [String: Any]
        XCTAssertEqual(action["enum"] as? [String], ["click", "type", "press", "scroll", "wait"])
    }
}
