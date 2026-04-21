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

// MARK: - A2AHandler

/// A handler for intercepting and processing A2A requests and responses.
///
/// Conform to this protocol to create middleware that can modify JSON-RPC
/// requests before they are sent and responses before they are returned
/// to the caller.
///
/// Mirrors Flutter `abstract class A2AHandler` in `genui_a2a/client/a2a_handler.dart`.
///
/// ## Typical Use Cases
///
/// - **Logging**: Inspect request/response payloads for debugging.
/// - **Authentication**: Inject auth tokens into request headers or body.
/// - **Error transformation**: Map raw error responses to domain-specific errors.
///
/// ## Example
///
/// ```swift
/// struct LoggingHandler: A2AHandler {
///     func handleRequest(_ request: [String: Any]) async throws -> [String: Any] {
///         print("→ Request: \(request)")
///         return request
///     }
///
///     func handleResponse(_ response: [String: Any]) async throws -> [String: Any] {
///         print("← Response: \(response)")
///         return response
///     }
/// }
/// ```
public protocol A2AHandler: Sendable {

    /// Handles the request and can modify it before it is sent.
    ///
    /// - Parameter request: The JSON-RPC request dictionary.
    /// - Returns: The (possibly modified) request dictionary.
    func handleRequest(_ request: [String: Any]) async throws -> [String: Any]

    /// Handles the response and can modify it before it is returned to the caller.
    ///
    /// - Parameter response: The JSON-RPC response dictionary.
    /// - Returns: The (possibly modified) response dictionary.
    func handleResponse(_ response: [String: Any]) async throws -> [String: Any]
}

// MARK: - A2AHandlerPipeline

/// A pipeline for executing a series of ``A2AHandler``s.
///
/// Requests are processed **in order** (first handler → last handler),
/// while responses are processed **in reverse order** (last handler → first handler).
/// This creates a symmetric middleware stack similar to "onion" architectures.
///
/// ## Early Return
///
/// A handler can short-circuit the request pipeline (skipping subsequent
/// handlers and the network call) by returning a request dict that contains
/// the special key `A2AHandlerPipeline.earlyResponseKey` mapped to a
/// `[String: Any]` response dict. The pipeline will immediately start the
/// response phase using that canned response, running only the handlers that
/// have already executed their `handleRequest` phase (in reverse order).
///
/// Mirrors Flutter `class A2AHandlerPipeline` in `genui_a2a/client/a2a_handler.dart`.
///
/// ```
///  Request flow:   Handler₁ → Handler₂ → Handler₃ → [Network]
///  Response flow:  Handler₃ → Handler₂ → Handler₁ → [Caller]
/// ```
public struct A2AHandlerPipeline: Sendable {

    /// The special key a handler may embed in its `handleRequest` return value
    /// to signal an early return.
    ///
    /// When present, the pipeline skips the remaining request handlers and the
    /// transport call, and feeds the value (a `[String: Any]` response dict) to
    /// the response phase of already-called handlers (in reverse order).
    ///
    /// Mirrors Go's `interceptor.Before()` returning a non-nil result.
    public static let earlyResponseKey = "_a2a_early_response"

    /// The special key a handler may embed in its `handleRequest` return value
    /// to carry updated ``ServiceParams`` back to the pipeline.
    ///
    /// When present (value must be `[String: [String]]`), the pipeline merges
    /// the encoded params into the accumulated ``ServiceParams`` before forwarding
    /// to the next handler. The key is stripped from the request dict before it
    /// is passed to the transport.
    ///
    /// This is the mechanism ``AuthHandler`` uses to inject per-call auth headers
    /// without touching the JSON-RPC envelope.
    public static let serviceParamsKey = "_a2a_service_params"

    /// The list of handlers to execute.
    public let handlers: [any A2AHandler]

    /// Creates an ``A2AHandlerPipeline``.
    ///
    /// - Parameter handlers: The ordered list of handlers. Requests traverse
    ///   this list front-to-back; responses traverse it back-to-front.
    public init(handlers: [any A2AHandler]) {
        self.handlers = handlers
    }

    /// Executes the request handlers in order.
    ///
    /// Each handler receives the output of the previous one, forming a
    /// chain of transformations. If a handler signals an early return (by
    /// setting ``earlyResponseKey`` in the returned dict), the remaining
    /// request handlers are skipped. The response phase runs for
    /// already-called handlers (in reverse order), and the final response
    /// dict is returned wrapped under ``earlyResponseKey`` so the caller
    /// (``A2AClient``) can detect the early-return condition.
    ///
    /// - Parameters:
    ///   - request: The original JSON-RPC request dictionary.
    ///   - context: Optional ``A2ARequest`` context. When provided, handlers
    ///     that conform to ``A2AContextualHandler`` receive the structured
    ///     context instead of the raw dictionary.
    /// - Returns: A tuple of:
    ///   - `request`: The request dictionary after all handlers have processed it,
    ///     OR a dict of the form `[earlyResponseKey: finalResponse]` when an
    ///     early return was triggered.
    ///   - `serviceParams`: Accumulated ``ServiceParams`` from all handlers that
    ///     ran (used by ``A2AClient`` to inject per-call auth headers).
    public func handleRequest(
        _ request: [String: Any],
        context: A2ARequest? = nil
    ) async throws -> (request: [String: Any], serviceParams: ServiceParams) {
        var currentRequest = request
        var accumulatedParams = context?.serviceParams ?? ServiceParams()
        for (index, handler) in handlers.enumerated() {
            var result: [String: Any]
            if let ctx = context, let contextual = handler as? any A2AContextualHandler {
                // Build an updated A2ARequest reflecting any mutations made by prior handlers.
                let updatedContext = A2ARequest(
                    method: ctx.method,
                    baseURL: ctx.baseURL,
                    card: ctx.card,
                    params: currentRequest["params"] as? [String: Any] ?? ctx.params,
                    rawRequest: currentRequest,
                    serviceParams: accumulatedParams
                )
                result = try await contextual.handleRequest(updatedContext)
            } else {
                result = try await handler.handleRequest(currentRequest)
            }

            // Extract and accumulate any ServiceParams the handler embedded in the result.
            if let paramsDict = result[Self.serviceParamsKey] as? [String: [String]] {
                for (key, values) in paramsDict {
                    accumulatedParams.append(key, values)
                }
                result.removeValue(forKey: Self.serviceParamsKey)
            }

            if let earlyResponse = result[Self.earlyResponseKey] as? [String: Any] {
                // Run response phase for handlers[0...index] in reverse
                let finalResponse = try await _handleResponse(earlyResponse, upToIndex: index, context: nil)
                // Wrap in earlyResponseKey so A2AClient can skip the transport
                return ([Self.earlyResponseKey: finalResponse], accumulatedParams)
            }
            currentRequest = result
        }
        return (currentRequest, accumulatedParams)
    }

    /// Executes the response handlers in reverse order.
    ///
    /// The last handler that processed the request is the first to process
    /// the response, maintaining a symmetric middleware stack.
    ///
    /// - Parameters:
    ///   - response: The original JSON-RPC response dictionary.
    ///   - context: Optional ``A2AResponse`` context. When provided, handlers
    ///     that conform to ``A2AContextualHandler`` receive the structured
    ///     context instead of the raw dictionary.
    /// - Returns: The response dictionary after all handlers have processed it.
    public func handleResponse(
        _ response: [String: Any],
        context: A2AResponse? = nil
    ) async throws -> [String: Any] {
        return try await _handleResponse(response, upToIndex: handlers.count - 1, context: context)
    }

    // MARK: - Private

    /// Runs `handleResponse` for `handlers[0...upToIndex]` in reverse.
    private func _handleResponse(
        _ response: [String: Any],
        upToIndex: Int,
        context: A2AResponse?
    ) async throws -> [String: Any] {
        var currentResponse = response
        let slice = handlers.prefix(upToIndex + 1)
        for handler in slice.reversed() {
            if let ctx = context, let contextual = handler as? any A2AContextualHandler {
                let updatedContext = A2AResponse(
                    method: ctx.method,
                    baseURL: ctx.baseURL,
                    card: ctx.card,
                    error: ctx.error,
                    result: currentResponse["result"] as? [String: Any],
                    rawResponse: currentResponse
                )
                currentResponse = try await contextual.handleResponse(updatedContext)
            } else {
                currentResponse = try await handler.handleResponse(currentResponse)
            }
        }
        return currentResponse
    }
}
