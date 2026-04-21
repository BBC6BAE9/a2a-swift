import A2ACore
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
import SwiftProtobuf

// MARK: - AgentCardResolver

/// A configurable object that fetches and decodes an ``AgentCard`` from a
/// well-known URL.
///
/// By default, the card is retrieved from
/// `<baseURL>/.well-known/agent-card.json`.  Two builder methods let callers
/// override those defaults without mutating the original resolver:
///
/// - ``withPath(_:)`` — replaces the well-known path.
/// - ``withRequestHeader(_:_:)`` — adds an extra HTTP header to the fetch request
///   (can be called multiple times; all headers accumulate).
///
/// Once configured, call ``resolve()`` to perform the network request.
///
/// ## Relationship to A2AClient
///
/// ``A2AClient`` accepts an optional `AgentCardResolver` in its initialiser.
/// When present, ``A2AClient/getAgentCard()`` delegates to the resolver instead
/// of using its own hard-coded path.  This lets callers customise the fetch
/// (different path, auth headers) without subclassing or replacing the
/// transport.
///
/// ## Example
///
/// ```swift
/// // Standard usage — default path.
/// let resolver = AgentCardResolver(baseURL: "https://agent.example.com")
/// let card = try await resolver.resolve()
///
/// // Custom path + auth header.
/// let resolver = AgentCardResolver(baseURL: "https://internal.example.com")
///     .withPath("/api/v2/agent-card")
///     .withRequestHeader("Authorization", "Bearer admin-token")
///
/// let card = try await resolver.resolve()
/// ```
///
/// Mirrors the pattern used by Go's `AgentCardResolver` options in
/// `a2aclient/resolver.go`.
public struct AgentCardResolver: Sendable {

    // MARK: - Properties

    /// The base URL of the server from which to fetch the card.
    public let baseURL: String

    /// The path appended to ``baseURL`` when fetching the card.
    ///
    /// Defaults to ``A2AClient/agentCardPath`` (`/.well-known/agent-card.json`).
    public let path: String

    /// Extra HTTP headers included in the fetch request.
    public let requestHeaders: ServiceParams

    // MARK: - Initialiser

    /// Creates an ``AgentCardResolver`` with the given base URL and default settings.
    ///
    /// - Parameter baseURL: The server base URL (e.g. `https://agent.example.com`).
    public init(baseURL: String) {
        self.baseURL = baseURL
        self.path = A2AClient.agentCardPath
        self.requestHeaders = ServiceParams()
    }

    // Private init used by the builder methods below.
    private init(baseURL: String, path: String, requestHeaders: ServiceParams) {
        self.baseURL = baseURL
        self.path = path
        self.requestHeaders = requestHeaders
    }

    // MARK: - Builder API

    /// Returns a copy of this resolver that uses `path` instead of the
    /// default well-known path.
    ///
    /// - Parameter path: The URL path segment (e.g. `/api/agent-card`).
    /// - Returns: A new ``AgentCardResolver`` with the updated path.
    public func withPath(_ path: String) -> AgentCardResolver {
        AgentCardResolver(baseURL: baseURL, path: path, requestHeaders: requestHeaders)
    }

    /// Returns a copy of this resolver that adds `value` for `name` to the
    /// outgoing request headers.
    ///
    /// Can be called multiple times; all header values accumulate.
    ///
    /// - Parameters:
    ///   - name: The HTTP header name (case-insensitive).
    ///   - value: The header value.
    /// - Returns: A new ``AgentCardResolver`` with the additional header.
    public func withRequestHeader(_ name: String, _ value: String) -> AgentCardResolver {
        var updated = requestHeaders
        updated.append(name, value)
        return AgentCardResolver(baseURL: baseURL, path: path, requestHeaders: updated)
    }

    // MARK: - Resolution

    /// Fetches and decodes the ``AgentCard`` from the configured URL.
    ///
    /// Constructs the URL as `baseURL + path`, fires a GET request with any
    /// accumulated ``requestHeaders``, and decodes the JSON response body into
    /// an ``AgentCard`` using SwiftProtobuf's JSON decoder.
    ///
    /// - Returns: The decoded ``AgentCard``.
    /// - Throws: ``A2ATransportError`` when the network request fails or the
    ///   response body cannot be decoded as an ``AgentCard``.
    public func resolve() async throws -> AgentCard {
        let transport = HttpTransport(url: baseURL, authParams: requestHeaders)
        let responseDict = try await transport.get(path: path)
        return try decodeAgentCard(from: responseDict)
    }

    // MARK: - Helpers

    /// Decodes a `[String: Any]` dictionary into an ``AgentCard``.
    private func decodeAgentCard(from dict: [String: Any]) throws -> AgentCard {
        let jsonData = try JSONSerialization.data(withJSONObject: dict)
        do {
            return try AgentCard(jsonUTF8Data: jsonData)
        } catch {
            throw A2ATransportError.parsing(
                message: "Failed to decode AgentCard: \(error.localizedDescription)"
            )
        }
    }
}
