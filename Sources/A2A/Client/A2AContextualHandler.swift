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

// MARK: - A2ARequest

/// A structured, transport-agnostic representation of an outgoing A2A request.
///
/// Passed to ``A2AContextualHandler/handleRequest(_:)`` so that handlers can
/// inspect typed fields (method, card, payload) without having to parse the raw
/// JSON-RPC dictionary themselves.
///
/// Mirrors Go's `a2aclient.Request` in `a2aclient/middleware.go`.
public struct A2ARequest: Sendable {

    /// The JSON-RPC method being invoked (e.g. `"message/send"`, `"tasks/get"`).
    public let method: String

    /// The base URL of the A2A server the client is connected to.
    public let baseURL: String

    /// The cached ``AgentCard`` at the time of the call, if one has been fetched.
    ///
    /// `nil` when the client was constructed directly from a URL and no card
    /// has been fetched yet.
    public let card: AgentCard?

    /// The raw JSON-RPC params dictionary for this call.
    ///
    /// This is the `"params"` field of the JSON-RPC 2.0 request envelope.
    /// The structure depends on the method — see the A2A specification for each
    /// method's parameter shape.
    public let params: [String: Any]

    /// The full raw JSON-RPC 2.0 request envelope (includes `jsonrpc`, `method`,
    /// `params`, and `id`).
    ///
    /// Handlers may return a modified copy of this to alter what is sent.
    public let rawRequest: [String: Any]

    /// Additional service parameters (e.g. auth headers) to inject for this request.
    ///
    /// Handlers — in particular ``AuthHandler`` — can write to this field to
    /// attach per-call headers (e.g. `Authorization: Bearer …`) without
    /// modifying the JSON-RPC envelope. The pipeline accumulates these across
    /// all handlers and the final merged value is passed to the transport.
    ///
    /// Mirrors Go's `a2aclient.Request.ServiceParams` in `a2aclient/middleware.go`.
    public var serviceParams: ServiceParams

    // MARK: Internal init (only A2AClient creates these)

    init(
        method: String,
        baseURL: String,
        card: AgentCard?,
        params: [String: Any],
        rawRequest: [String: Any],
        serviceParams: ServiceParams = ServiceParams()
    ) {
        self.method = method
        self.baseURL = baseURL
        self.card = card
        self.params = params
        self.rawRequest = rawRequest
        self.serviceParams = serviceParams
    }
}

// MARK: - A2AResponse

/// A structured, transport-agnostic representation of an incoming A2A response.
///
/// Passed to ``A2AContextualHandler/handleResponse(_:)`` so handlers can
/// inspect the method, timing, and result without parsing the raw dictionary.
///
/// Mirrors Go's `a2aclient.Response` in `a2aclient/middleware.go`.
public struct A2AResponse: Sendable {

    /// The JSON-RPC method that was invoked (echoed from the request).
    public let method: String

    /// The base URL of the A2A server the client is connected to.
    public let baseURL: String

    /// The cached ``AgentCard`` at the time of the call, if one has been fetched.
    public let card: AgentCard?

    /// The error returned by the server, if any.
    ///
    /// `nil` for successful responses.
    public let error: A2ATransportError?

    /// The raw JSON-RPC `result` dictionary, if the response was successful.
    ///
    /// `nil` when ``error`` is non-nil or the method returns no value.
    public let result: [String: Any]?

    /// The full raw JSON-RPC 2.0 response envelope.
    ///
    /// Handlers may return a modified copy of this to alter what is returned
    /// to the caller.
    public let rawResponse: [String: Any]

    // MARK: Internal init

    init(method: String, baseURL: String, card: AgentCard?, error: A2ATransportError?, result: [String: Any]?, rawResponse: [String: Any]) {
        self.method = method
        self.baseURL = baseURL
        self.card = card
        self.error = error
        self.result = result
        self.rawResponse = rawResponse
    }
}

// MARK: - A2AContextualHandler

/// An enhanced handler protocol that receives structured ``A2ARequest`` and
/// ``A2AResponse`` values instead of raw `[String: Any]` dictionaries.
///
/// Use this when you need typed access to the method name, AgentCard, or
/// parsed payload — for example, to gate logic on a specific method, or to
/// inject auth tokens based on the card's capabilities.
///
/// ``A2AClient`` accepts both ``A2AHandler`` and ``A2AContextualHandler`` in the
/// same `handlers` array — the pipeline automatically dispatches to the right
/// method.
///
/// ## Example
///
/// ```swift
/// final class RateLimiter: A2AContextualHandler {
///     func handleRequest(_ request: A2ARequest) async throws -> [String: Any] {
///         if request.method == "message/send" {
///             try await checkRateLimit(for: request.baseURL)
///         }
///         return request.rawRequest
///     }
///
///     func handleResponse(_ response: A2AResponse) async throws -> [String: Any] {
///         return response.rawResponse
///     }
/// }
/// ```
///
/// Mirrors Go's `CallInterceptor` interface in `a2aclient/middleware.go`, with
/// `handleRequest` / `handleResponse` replacing `Before` / `After`.
public protocol A2AContextualHandler: A2AHandler {

    /// Called before the request is sent to the transport.
    ///
    /// - Parameter request: Structured request context.
    /// - Returns: The raw JSON-RPC request dictionary to forward (possibly modified).
    func handleRequest(_ request: A2ARequest) async throws -> [String: Any]

    /// Called after the response is received from the transport.
    ///
    /// - Parameter response: Structured response context.
    /// - Returns: The raw JSON-RPC response dictionary to forward (possibly modified).
    func handleResponse(_ response: A2AResponse) async throws -> [String: Any]
}

// MARK: - Default A2AHandler conformance for A2AContextualHandler

/// When a type conforms to ``A2AContextualHandler``, the raw-dict ``A2AHandler``
/// methods are never called directly by the pipeline. These default implementations
/// exist only to satisfy the compiler — the pipeline checks for
/// ``A2AContextualHandler`` conformance first.
public extension A2AContextualHandler {
    func handleRequest(_ request: [String: Any]) async throws -> [String: Any] {
        // Unreachable via A2AHandlerPipeline — contextual path is taken instead.
        return request
    }

    func handleResponse(_ response: [String: Any]) async throws -> [String: Any] {
        return response
    }
}

// MARK: - PassthroughContextualHandler

/// A no-op base implementation of ``A2AContextualHandler``.
///
/// Override only the methods you care about.
///
/// ```swift
/// final class MethodLogger: PassthroughContextualHandler {
///     override func handleRequest(_ request: A2ARequest) async throws -> [String: Any] {
///         print("calling \(request.method)")
///         return request.rawRequest
///     }
/// }
/// ```
open class PassthroughContextualHandler: A2AContextualHandler, @unchecked Sendable {

    public init() {}

    open func handleRequest(_ request: A2ARequest) async throws -> [String: Any] {
        return request.rawRequest
    }

    open func handleResponse(_ response: A2AResponse) async throws -> [String: Any] {
        return response.rawResponse
    }
}
