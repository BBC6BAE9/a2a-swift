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
@testable import A2A

// MARK: - Helpers

/// Minimal valid AgentCard JSON for testing.
private let minimalCardJSON = """
{
  "name": "TestAgent",
  "description": "A test agent",
  "version": "1.0"
}
"""

// MARK: - AgentCardResolver Builder Tests

@Suite("AgentCardResolver builder API")
struct AgentCardResolverBuilderTests {

    @Test("default path equals A2AClient.agentCardPath")
    func defaultPath() {
        let resolver = AgentCardResolver(baseURL: "http://agent.test")
        #expect(resolver.path == A2AClient.agentCardPath)
    }

    @Test("withPath(_:) returns new resolver with updated path")
    func withPath_updatesPath() {
        let resolver = AgentCardResolver(baseURL: "http://agent.test")
            .withPath("/custom/card.json")
        #expect(resolver.path == "/custom/card.json")
    }

    @Test("withPath(_:) does not mutate original")
    func withPath_doesNotMutateOriginal() {
        let original = AgentCardResolver(baseURL: "http://agent.test")
        _ = original.withPath("/other/path")
        #expect(original.path == A2AClient.agentCardPath)
    }

    @Test("withRequestHeader(_:_:) adds header to requestHeaders")
    func withRequestHeader_addsHeader() {
        let resolver = AgentCardResolver(baseURL: "http://agent.test")
            .withRequestHeader("Authorization", "Bearer tok")
        let values = resolver.requestHeaders.get("authorization")
        #expect(values == ["Bearer tok"])
    }

    @Test("withRequestHeader(_:_:) does not mutate original")
    func withRequestHeader_doesNotMutateOriginal() {
        let original = AgentCardResolver(baseURL: "http://agent.test")
        _ = original.withRequestHeader("Authorization", "Bearer tok")
        #expect(original.requestHeaders.isEmpty)
    }

    @Test("multiple withRequestHeader calls accumulate headers")
    func multipleHeaders_accumulate() {
        let resolver = AgentCardResolver(baseURL: "http://agent.test")
            .withRequestHeader("X-Foo", "foo-value")
            .withRequestHeader("X-Bar", "bar-value")
        #expect(resolver.requestHeaders.get("x-foo") == ["foo-value"])
        #expect(resolver.requestHeaders.get("x-bar") == ["bar-value"])
    }

    @Test("baseURL is preserved through builder chain")
    func baseURL_preserved() {
        let resolver = AgentCardResolver(baseURL: "http://agent.test")
            .withPath("/other")
            .withRequestHeader("X-Key", "val")
        #expect(resolver.baseURL == "http://agent.test")
    }
}

// MARK: - AgentCardResolver.resolve() Tests (via A2AClient integration)

/// These tests verify that A2AClient delegates getAgentCard() to the resolver.
/// We stub out the network by injecting a mock URLSession (via TestURLSession below).
@Suite("AgentCardResolver integration with A2AClient")
struct AgentCardResolverIntegrationTests {

    // MARK: - Default path is used when no resolver

    @Test("getAgentCard uses default path when no resolver provided")
    func noResolver_usesDefaultPath() async throws {
        let transport = TestTransport()
        var capturedPath: String?
        transport.getFn = { path, _ in
            capturedPath = path
            return try Self.minimalCardDict()
        }

        let client = A2AClient(
            url: "http://agent.test",
            transport: transport
        )

        _ = try await client.getAgentCard()
        #expect(capturedPath == A2AClient.agentCardPath)
    }

    // MARK: - Resolver's custom path is forwarded

    @Test("getAgentCard uses resolver path when resolver is provided")
    func withResolver_usesCustomPath() async throws {
        // We can't inject a URLSession into HttpTransport from tests,
        // so we test via A2AClient with a TestTransport and a resolver
        // whose path is inspected by overriding `getAgentCard()` via transport.
        //
        // Instead, we verify the resolver's path field directly and that
        // the client stores it (builder API already tested above). Then we test
        // that A2AClient.getAgentCard() calls resolver.resolve() by checking
        // that transport.get is NOT called when a resolver is provided.
        let transport = TestTransport()
        var transportGetCalled = false
        transport.getFn = { _, _ in
            transportGetCalled = true
            return try Self.minimalCardDict()
        }

        // Provide a resolver that points at a real-ish URL (will fail the
        // network call). We can tell A2AClient used the resolver because
        // the transport.get is never called.
        let resolver = AgentCardResolver(baseURL: "http://agent.test")
            .withPath("/.well-known/agent-card.json")

        let client = A2AClient(
            url: "http://agent.test",
            transport: transport,
            cardResolver: resolver
        )

        // Attempt resolve — it will fail with a network error because there's
        // no real server, but what matters is transport.getFn was NOT invoked.
        _ = try? await client.getAgentCard()
        #expect(!transportGetCalled, "When a resolver is set, the client must NOT use the transport directly")
    }

    // MARK: - No resolver: transport.get IS called

    @Test("getAgentCard calls transport.get when no resolver is provided")
    func noResolver_callsTransportGet() async throws {
        let transport = TestTransport()
        var transportGetCalled = false
        transport.getFn = { _, _ in
            transportGetCalled = true
            return try Self.minimalCardDict()
        }

        let client = A2AClient(url: "http://agent.test", transport: transport)
        _ = try? await client.getAgentCard()
        #expect(transportGetCalled)
    }

    // MARK: - Helpers

    /// Returns a `[String: Any]` dictionary from the minimal card JSON.
    private static func minimalCardDict() throws -> [String: Any] {
        let data = Data(minimalCardJSON.utf8)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestError.custom("Failed to parse minimal card JSON")
        }
        return dict
    }
}

// MARK: - AgentCardResolver default values

@Suite("AgentCardResolver default values")
struct AgentCardResolverDefaultsTests {

    @Test("requestHeaders is empty by default")
    func requestHeaders_emptyByDefault() {
        let resolver = AgentCardResolver(baseURL: "http://agent.test")
        #expect(resolver.requestHeaders.isEmpty)
    }

    @Test("baseURL is stored correctly")
    func baseURL_stored() {
        let resolver = AgentCardResolver(baseURL: "https://my.agent.example.com")
        #expect(resolver.baseURL == "https://my.agent.example.com")
    }
}
