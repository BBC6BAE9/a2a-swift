// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import Testing
@testable import A2AClient
import A2ACore
@testable import A2AServer

// MARK: - Helpers

/// Builds a minimal AgentCard with the given security scheme and requirement.
private func makeCard(schemeName: String, scheme: SecurityScheme) -> AgentCard {
    var req = SecurityRequirement()
    req.schemes[schemeName] = StringList()
    var card = AgentCard()
    card.securitySchemes[schemeName] = scheme
    card.securityRequirements = [req]
    return card
}

/// Returns a SecurityScheme wrapping an HTTPAuthSecurityScheme.
private func httpScheme() -> SecurityScheme {
    var s = SecurityScheme()
    s.httpAuthSecurityScheme = HTTPAuthSecurityScheme()
    return s
}

/// Returns a SecurityScheme wrapping an OAuth2SecurityScheme.
private func oauth2Scheme() -> SecurityScheme {
    var s = SecurityScheme()
    s.oauth2SecurityScheme = OAuth2SecurityScheme()
    return s
}

/// Returns a SecurityScheme wrapping an OpenIdConnectSecurityScheme.
private func oidcScheme() -> SecurityScheme {
    var s = SecurityScheme()
    s.openIDConnectSecurityScheme = OpenIdConnectSecurityScheme()
    return s
}

/// Returns a SecurityScheme wrapping an APIKeySecurityScheme with given name/location.
private func apiKeyScheme(name: String, location: String) -> SecurityScheme {
    var apiKey = APIKeySecurityScheme()
    apiKey.name = name
    apiKey.location = location
    var s = SecurityScheme()
    s.apiKeySecurityScheme = apiKey
    return s
}

/// Returns a SecurityScheme wrapping a MutualTlsSecurityScheme.
private func mtlsScheme() -> SecurityScheme {
    var s = SecurityScheme()
    s.mtlsSecurityScheme = MutualTlsSecurityScheme()
    return s
}

/// A minimal JSON-RPC success response.
private func successResponse() -> [String: Any] {
    ["jsonrpc": "2.0", "id": "1", "result": ["id": "t1", "status": ["state": "submitted"]]]
}

// MARK: - InMemoryCredentialsStore Tests

@Suite("InMemoryCredentialsStore")
struct InMemoryCredentialsStoreTests {

    @Test("get returns stored credential")
    func get_returnsStoredCredential() async throws {
        let store = InMemoryCredentialsStore()
        store.set("session-1", scheme: "bearerAuth", credential: "my-token")

        let cred = try await store.get(sessionID: "session-1", scheme: "bearerAuth")
        #expect(cred == "my-token")
    }

    @Test("get throws notFound for missing session")
    func get_throwsNotFound_missingSession() async throws {
        let store = InMemoryCredentialsStore()
        await #expect(throws: CredentialsServiceError.notFound) {
            _ = try await store.get(sessionID: "nonexistent", scheme: "bearerAuth")
        }
    }

    @Test("get throws notFound for missing scheme within known session")
    func get_throwsNotFound_missingScheme() async throws {
        let store = InMemoryCredentialsStore()
        store.set("session-1", scheme: "bearerAuth", credential: "tok")
        await #expect(throws: CredentialsServiceError.notFound) {
            _ = try await store.get(sessionID: "session-1", scheme: "apiKey")
        }
    }

    @Test("set overwrites existing credential")
    func set_overwritesExisting() async throws {
        let store = InMemoryCredentialsStore()
        store.set("s1", scheme: "bearerAuth", credential: "first")
        store.set("s1", scheme: "bearerAuth", credential: "second")
        let cred = try await store.get(sessionID: "s1", scheme: "bearerAuth")
        #expect(cred == "second")
    }

    @Test("remove clears all credentials for session")
    func remove_clearsSession() async throws {
        let store = InMemoryCredentialsStore()
        store.set("s1", scheme: "bearerAuth", credential: "tok")
        store.remove("s1")
        await #expect(throws: CredentialsServiceError.notFound) {
            _ = try await store.get(sessionID: "s1", scheme: "bearerAuth")
        }
    }

    @Test("multiple sessions are independent")
    func multipleSessionsAreIndependent() async throws {
        let store = InMemoryCredentialsStore()
        store.set("s1", scheme: "bearerAuth", credential: "tok-1")
        store.set("s2", scheme: "bearerAuth", credential: "tok-2")
        store.remove("s1")

        await #expect(throws: CredentialsServiceError.notFound) {
            _ = try await store.get(sessionID: "s1", scheme: "bearerAuth")
        }
        let cred = try await store.get(sessionID: "s2", scheme: "bearerAuth")
        #expect(cred == "tok-2")
    }
}

// MARK: - SessionID Tests

@Suite("SessionID")
struct SessionIDTests {

    @Test("TaskLocal current is nil by default")
    func taskLocal_nilByDefault() async {
        let id = SessionID.current
        #expect(id == nil)
    }

    @Test("TaskLocal propagates value through withValue")
    func taskLocal_propagatesValue() async {
        await SessionID.$current.withValue("session-xyz") {
            #expect(SessionID.current == "session-xyz")
        }
    }

    @Test("TaskLocal value is nil after withValue block exits")
    func taskLocal_nilAfterBlock() async {
        await SessionID.$current.withValue("session-xyz") { }
        #expect(SessionID.current == nil)
    }

    @Test("TaskLocal propagates into child tasks")
    func taskLocal_propagatesIntoChildTask() async {
        await SessionID.$current.withValue("parent-session") {
            let task = _Concurrency.Task<SessionID?, Never> { SessionID.current }
            let captured = await task.value
            #expect(captured == "parent-session")
        }
    }
}

// MARK: - AuthHandler Tests

@Suite("AuthHandler")
struct AuthHandlerTests {

    // MARK: Bearer / HTTP

    @Test("HTTP scheme: injects Authorization: Bearer header")
    func httpScheme_injectsBearerHeader() async throws {
        let store = InMemoryCredentialsStore()
        store.set("s1", scheme: "bearerAuth", credential: "my-token")

        let card = makeCard(schemeName: "bearerAuth", scheme: httpScheme())
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in successResponse() }

        let client = A2AClient(
            url: "http://agent.test",
            transport: transport,
            handlers: [AuthHandler(credentialsService: store)]
        )
        await client.updateCard(card)

        await SessionID.$current.withValue("s1") {
            _ = try? await client.messageSend(Message())
        }

        let params = transport.sentParams.first ?? ServiceParams()
        #expect(params.hasHeader("Authorization", value: "Bearer my-token"))
    }

    // MARK: OAuth2

    @Test("OAuth2 scheme: injects Authorization: Bearer header")
    func oauth2Scheme_injectsBearerHeader() async throws {
        let store = InMemoryCredentialsStore()
        store.set("s1", scheme: "oauthScheme", credential: "oauth-token")

        let card = makeCard(schemeName: "oauthScheme", scheme: oauth2Scheme())
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in successResponse() }

        let client = A2AClient(
            url: "http://agent.test",
            transport: transport,
            handlers: [AuthHandler(credentialsService: store)]
        )
        await client.updateCard(card)

        await SessionID.$current.withValue("s1") {
            _ = try? await client.messageSend(Message())
        }

        let params = transport.sentParams.first ?? ServiceParams()
        #expect(params.hasHeader("Authorization", value: "Bearer oauth-token"))
    }

    // MARK: OpenID Connect

    @Test("OpenID Connect scheme: injects Authorization: Bearer header")
    func oidcScheme_injectsBearerHeader() async throws {
        let store = InMemoryCredentialsStore()
        store.set("s1", scheme: "oidcScheme", credential: "oidc-token")

        let card = makeCard(schemeName: "oidcScheme", scheme: oidcScheme())
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in successResponse() }

        let client = A2AClient(
            url: "http://agent.test",
            transport: transport,
            handlers: [AuthHandler(credentialsService: store)]
        )
        await client.updateCard(card)

        await SessionID.$current.withValue("s1") {
            _ = try? await client.messageSend(Message())
        }

        let params = transport.sentParams.first ?? ServiceParams()
        #expect(params.hasHeader("Authorization", value: "Bearer oidc-token"))
    }

    // MARK: API key (header location)

    @Test("API key scheme (header location): injects named header")
    func apiKeyScheme_headerLocation_injectsNamedHeader() async throws {
        let store = InMemoryCredentialsStore()
        store.set("s1", scheme: "apiKeyScheme", credential: "key-abc")

        let card = makeCard(
            schemeName: "apiKeyScheme",
            scheme: apiKeyScheme(name: "X-API-Key", location: "header")
        )
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in successResponse() }

        let client = A2AClient(
            url: "http://agent.test",
            transport: transport,
            handlers: [AuthHandler(credentialsService: store)]
        )
        await client.updateCard(card)

        await SessionID.$current.withValue("s1") {
            _ = try? await client.messageSend(Message())
        }

        let params = transport.sentParams.first ?? ServiceParams()
        #expect(params.hasHeader("X-API-Key", value: "key-abc"))
    }

    @Test("API key scheme (empty location defaults to header)")
    func apiKeyScheme_emptyLocation_defaultsToHeader() async throws {
        let store = InMemoryCredentialsStore()
        store.set("s1", scheme: "apiKeyScheme", credential: "key-xyz")

        let card = makeCard(
            schemeName: "apiKeyScheme",
            scheme: apiKeyScheme(name: "X-Custom-Key", location: "")
        )
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in successResponse() }

        let client = A2AClient(
            url: "http://agent.test",
            transport: transport,
            handlers: [AuthHandler(credentialsService: store)]
        )
        await client.updateCard(card)

        await SessionID.$current.withValue("s1") {
            _ = try? await client.messageSend(Message())
        }

        let params = transport.sentParams.first ?? ServiceParams()
        #expect(params.hasHeader("X-Custom-Key", value: "key-xyz"))
    }

    @Test("API key scheme (query location): no header injected")
    func apiKeyScheme_queryLocation_noHeader() async throws {
        let store = InMemoryCredentialsStore()
        store.set("s1", scheme: "apiKeyScheme", credential: "key-abc")

        let card = makeCard(
            schemeName: "apiKeyScheme",
            scheme: apiKeyScheme(name: "api_key", location: "query")
        )
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in successResponse() }

        let client = A2AClient(
            url: "http://agent.test",
            transport: transport,
            handlers: [AuthHandler(credentialsService: store)]
        )
        await client.updateCard(card)

        await SessionID.$current.withValue("s1") {
            _ = try? await client.messageSend(Message())
        }

        let params = transport.sentParams.first ?? ServiceParams()
        #expect(!params.hasHeader("api_key"))
    }

    // MARK: mTLS

    @Test("mTLS scheme: no header injected")
    func mtlsScheme_noHeaderInjected() async throws {
        let store = InMemoryCredentialsStore()
        store.set("s1", scheme: "mtlsScheme", credential: "cert")

        let card = makeCard(schemeName: "mtlsScheme", scheme: mtlsScheme())
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in successResponse() }

        let client = A2AClient(
            url: "http://agent.test",
            transport: transport,
            handlers: [AuthHandler(credentialsService: store)]
        )
        await client.updateCard(card)

        await SessionID.$current.withValue("s1") {
            _ = try? await client.messageSend(Message())
        }

        let params = transport.sentParams.first ?? ServiceParams()
        #expect(!params.hasHeader("Authorization"))
    }

    // MARK: Passthrough scenarios

    @Test("no session ID: request passes through unmodified")
    func noSessionID_passthrough() async throws {
        let store = InMemoryCredentialsStore()

        let card = makeCard(schemeName: "bearerAuth", scheme: httpScheme())
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in successResponse() }

        let client = A2AClient(
            url: "http://agent.test",
            transport: transport,
            handlers: [AuthHandler(credentialsService: store)]
        )
        await client.updateCard(card)

        // No SessionID.$current set — call without withValue.
        _ = try? await client.messageSend(Message())

        let params = transport.sentParams.first ?? ServiceParams()
        #expect(!params.hasHeader("Authorization"))
    }

    @Test("session ID set but credential not in store: request passes through unmodified")
    func sessionIDSetButNoCredential_passthrough() async throws {
        let store = InMemoryCredentialsStore()
        // Intentionally do NOT set a credential.

        let card = makeCard(schemeName: "bearerAuth", scheme: httpScheme())
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in successResponse() }

        let client = A2AClient(
            url: "http://agent.test",
            transport: transport,
            handlers: [AuthHandler(credentialsService: store)]
        )
        await client.updateCard(card)

        await SessionID.$current.withValue("s1") {
            _ = try? await client.messageSend(Message())
        }

        let params = transport.sentParams.first ?? ServiceParams()
        #expect(!params.hasHeader("Authorization"))
    }

    @Test("card with no security config: request passes through unmodified")
    func noSecurityConfig_passthrough() async throws {
        let store = InMemoryCredentialsStore()
        store.set("s1", scheme: "bearerAuth", credential: "tok")

        // Card with no security schemes or requirements.
        let card = AgentCard()
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in successResponse() }

        let client = A2AClient(
            url: "http://agent.test",
            transport: transport,
            handlers: [AuthHandler(credentialsService: store)]
        )
        await client.updateCard(card)

        await SessionID.$current.withValue("s1") {
            _ = try? await client.messageSend(Message())
        }

        let params = transport.sentParams.first ?? ServiceParams()
        #expect(!params.hasHeader("Authorization"))
    }

    @Test("no card set on client: request passes through unmodified")
    func noCard_passthrough() async throws {
        let store = InMemoryCredentialsStore()
        store.set("s1", scheme: "bearerAuth", credential: "tok")

        let transport = TestTransport()
        transport.sendFn = { _, _, _ in successResponse() }

        // Do NOT call updateCard; internal card is nil.
        let client = A2AClient(
            url: "http://agent.test",
            transport: transport,
            handlers: [AuthHandler(credentialsService: store)]
        )

        await SessionID.$current.withValue("s1") {
            _ = try? await client.messageSend(Message())
        }

        let params = transport.sentParams.first ?? ServiceParams()
        #expect(!params.hasHeader("Authorization"))
    }

    // MARK: First-match-wins

    @Test("first matching credential wins; second scheme is not used")
    func firstMatchWins() async throws {
        let store = InMemoryCredentialsStore()
        store.set("s1", scheme: "scheme1", credential: "first-token")
        store.set("s1", scheme: "scheme2", credential: "second-token")

        var req1 = SecurityRequirement()
        req1.schemes["scheme1"] = StringList()
        req1.schemes["scheme2"] = StringList()

        var card = AgentCard()
        card.securitySchemes["scheme1"] = httpScheme()
        card.securitySchemes["scheme2"] = httpScheme()
        card.securityRequirements = [req1]

        let transport = TestTransport()
        transport.sendFn = { _, _, _ in successResponse() }

        let client = A2AClient(
            url: "http://agent.test",
            transport: transport,
            handlers: [AuthHandler(credentialsService: store)]
        )
        await client.updateCard(card)

        await SessionID.$current.withValue("s1") {
            _ = try? await client.messageSend(Message())
        }

        let params = transport.sentParams.first ?? ServiceParams()
        // Exactly one Authorization header must be present.
        let authHeaders = params.headers.filter { $0.0 == "authorization" }
        #expect(authHeaders.count == 1)
    }
}

// MARK: - ServiceParams header accessor

/// Allow tests to inspect injected headers conveniently.
extension ServiceParams {
    /// All (name, value) pairs from the underlying headers multimap.
    /// Keys are returned in their stored form (lower-case).
    var headers: [(String, String)] {
        var result: [(String, String)] = []
        for (key, values) in asDictionary() {
            for value in values {
                result.append((key, value))
            }
        }
        return result
    }

    /// Returns true when a header with the given name (case-insensitive) and exact value exists.
    func hasHeader(_ name: String, value: String) -> Bool {
        headers.contains(where: { $0.0 == name.lowercased() && $0.1 == value })
    }

    /// Returns true when a header with the given name (case-insensitive) exists.
    func hasHeader(_ name: String) -> Bool {
        headers.contains(where: { $0.0 == name.lowercased() })
    }
}
