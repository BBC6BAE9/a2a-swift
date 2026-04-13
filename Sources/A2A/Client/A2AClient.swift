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
#if canImport(os)
import os
#endif

// MARK: - JSON-RPC Error → A2ATransportError mapping

/// Maps a JSON-RPC error dictionary to a typed ``A2ATransportError``.
///
/// Mirrors the top-level Dart `_exceptionFrom` function in
/// `genui_a2a/client/a2a_client.dart`.
///
/// A2A-specific error codes:
/// - `-32001` → task not found
/// - `-32002` → task not cancelable
/// - `-32006` → push notifications not supported
/// - `-32007` → push notification config not found
private func transportError(from error: [String: Any]) -> A2ATransportError {
    let code = error["code"] as? Int ?? 0
    let message = error["message"] as? String ?? "Unknown error"

    switch code {
    case -32001:
        return .taskNotFound(message: message)
    case -32002:
        return .taskNotCancelable(message: message)
    case -32006:
        return .pushNotificationNotSupported(message: message)
    case -32007:
        return .pushNotificationConfigNotFound(message: message)
    default:
        return .jsonRpc(code: code, message: message)
    }
}

// MARK: - A2AClient

/// A client for interacting with an A2A (Agent-to-Agent) server.
///
/// Provides methods for all the JSON-RPC calls defined in the A2A
/// specification, including message sending (single-shot and streaming),
/// task management, and push notification configuration.
///
/// Uses an ``A2ATransport`` instance to communicate with the server,
/// defaulting to ``SseTransport`` when no transport is provided.
///
/// Mirrors Dart `class A2AClient` in `genui_a2a/client/a2a_client.dart`.
///
/// ## Example
///
/// ```swift
/// let client = A2AClient(url: "http://localhost:8000")
/// let card = try await client.getAgentCard()
/// print(card.name)
/// ```
public final class A2AClient: @unchecked Sendable {

    // MARK: - Properties

    /// The base URL of the A2A server.
    public let url: String

    /// The underlying transport used for communication.
    private let transport: any A2ATransport

    /// An optional handler pipeline for intercepting requests/responses.
    private let handlerPipeline: A2AHandlerPipeline?

    /// Auto-incrementing request ID for JSON-RPC 2.0.
    private var requestId: Int = 0

    /// Lock for thread-safe `requestId` increments.
    private let lock = NSLock()

    #if canImport(os)
    private let logger = Logger(subsystem: "A2UIV09_A2A", category: "A2AClient")
    #endif

    // MARK: - Well-Known Path

    /// The well-known path for the agent card endpoint.
    public static let agentCardPath = "/.well-known/agent-card.json"

    /// The path for the authenticated extended agent card endpoint.
    public static let extendedAgentCardPath = "/extendedAgentCard"

    // MARK: - Initialisation

    /// Creates an ``A2AClient`` instance.
    ///
    /// - Parameters:
    ///   - url: The base URL of the A2A server (e.g. `http://localhost:8000`).
    ///   - transport: An optional ``A2ATransport``. If omitted, an ``SseTransport``
    ///     is created using the provided `url`.
    ///   - handlers: An optional list of ``A2AHandler``s to form a pipeline for
    ///     intercepting requests and responses.
    public init(
        url: String,
        transport: (any A2ATransport)? = nil,
        handlers: [any A2AHandler] = []
    ) {
        self.url = url
        self.transport = transport ?? SseTransport(url: url)
        self.handlerPipeline = handlers.isEmpty ? nil : A2AHandlerPipeline(handlers: handlers)
    }

    // MARK: - Factory

    /// Creates an ``A2AClient`` by fetching an ``AgentCard`` from a URL and
    /// selecting the best transport.
    ///
    /// Fetches the agent card from `agentCardUrl`, determines the best transport
    /// based on the card's capabilities (preferring streaming if available),
    /// and returns a new ``A2AClient`` instance.
    ///
    /// - Parameters:
    ///   - agentCardUrl: The full URL from which to fetch the agent card.
    ///   - handlers: An optional list of ``A2AHandler``s.
    /// - Returns: A configured ``A2AClient``.
    public static func fromAgentCardUrl(
        _ agentCardUrl: String,
        handlers: [any A2AHandler] = []
    ) async throws -> A2AClient {
        let tempTransport = HttpTransport(url: agentCardUrl)
        let responseDict = try await tempTransport.get(path: "")
        let agentCard = try decodeProto(AgentCard.self, from: responseDict)

        guard let interfaceUrl = agentCard.supportedInterfaces.first?.url,
              !interfaceUrl.isEmpty else {
            throw A2ATransportError.parsing(message: "AgentCard has no supported interfaces")
        }

        let transport: any A2ATransport
        if agentCard.capabilities.streaming {
            transport = SseTransport(url: interfaceUrl)
        } else {
            transport = HttpTransport(url: interfaceUrl)
        }

        return A2AClient(url: interfaceUrl, transport: transport, handlers: handlers)
    }

    // MARK: - Agent Card

    /// Fetches the public agent card from the server.
    ///
    /// The agent card contains metadata about the agent, such as its capabilities
    /// and security schemes. Requests the card from ``agentCardPath``.
    ///
    /// - Returns: An ``AgentCard`` object.
    /// - Throws: ``A2ATransportError`` if the request fails or the response is invalid.
    public func getAgentCard() async throws -> AgentCard {
        log("Fetching agent card...")
        let response = try await transport.get(path: Self.agentCardPath)
        logFine("Received agent card")
        return try decodeProto(AgentCard.self, from: response)
    }

    /// Fetches the authenticated extended agent card from the server.
    ///
    /// Retrieves a potentially more detailed ``AgentCard`` available only to
    /// authenticated users, including an `Authorization` header with the
    /// provided Bearer `token`.
    ///
    /// - Parameter token: The Bearer token for authentication.
    /// - Returns: An ``AgentCard`` object.
    /// - Throws: ``A2ATransportError`` if the request fails or the response is invalid.
    public func getAuthenticatedExtendedCard(_ token: String) async throws -> AgentCard {
        log("Fetching authenticated agent card...")
        let response = try await transport.get(
            path: Self.extendedAgentCardPath,
            headers: ["Authorization": "Bearer \(token)"]
        )
        logFine("Received authenticated agent card")
        return try decodeProto(AgentCard.self, from: response)
    }

    // MARK: - message/send

    /// Sends a message to the agent for a single-shot interaction via
    /// `message/send`.
    ///
    /// The server processes the message and returns either a `Task` or a
    /// `Message` wrapped in a ``SendMessageResponse``.
    ///
    /// For long-running operations, consider ``messageStream(_:)`` or polling
    /// with ``getTask(_:)``.
    ///
    /// - Parameter message: The ``Message`` to send.
    /// - Returns: A ``SendMessageResponse`` containing either a task or a message.
    /// - Throws: ``A2ATransportError`` if the server returns a JSON-RPC error.
    public func messageSend(_ message: Message) async throws -> SendMessageResponse {
        log("Sending message: \(message.messageID)")

        var params: [String: Any] = ["message": try encodeProto(message)]
        if !message.extensions.isEmpty {
            params["extensions"] = message.extensions
        }

        var headers: [String: String] = [:]
        if !message.extensions.isEmpty {
            headers["X-A2A-Extensions"] = message.extensions.joined(separator: ",")
        }

        return try await sendRPC(
            method: "message/send",
            params: params,
            headers: headers,
            returning: SendMessageResponse.self
        )
    }

    // MARK: - message/stream

    /// Sends a message to the agent and subscribes to real-time updates via
    /// `message/stream`.
    ///
    /// The agent can send multiple updates over time. The returned stream
    /// emits ``StreamResponse`` objects as they are received, typically via SSE.
    ///
    /// - Parameter message: The ``Message`` to send.
    /// - Returns: An `AsyncThrowingStream` of ``StreamResponse`` objects.
    public func messageStream(_ message: Message) -> AsyncThrowingStream<StreamResponse, Error> {
        log("Sending message for stream: \(message.messageID)")

        return AsyncThrowingStream { continuation in
            let task = _Concurrency.Task {
                do {
                    var params: [String: Any] = [
                        "configuration": NSNull(),
                        "metadata": NSNull(),
                        "message": try encodeProto(message),
                    ]
                    if !message.extensions.isEmpty {
                        params["extensions"] = message.extensions
                    }

                    var headers: [String: String] = [:]
                    if !message.extensions.isEmpty {
                        headers["X-A2A-Extensions"] = message.extensions.joined(separator: ",")
                    }

                    let request = self.buildRequest(method: "message/stream", params: params)
                    let processed = try await self.applyRequestHandlers(request)
                    let stream = self.transport.sendStream(processed, headers: headers)

                    for try await data in stream {
                        let handled = try await self.applyResponseHandlers(data)
                        self.logFine("Received event from stream")

                        if handled["error"] != nil {
                            guard let errorDict = handled["error"] as? [String: Any] else {
                                continuation.finish(throwing: A2ATransportError.parsing(
                                    message: "Malformed 'error' in stream event"
                                ))
                                return
                            }
                            continuation.finish(throwing: transportError(from: errorDict))
                            return
                        }

                        let event = try decodeProto(StreamResponse.self, from: handled)
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - tasks/get

    /// Retrieves the current state of a task from the server using `tasks/get`.
    ///
    /// - Parameter taskId: The unique identifier of the task.
    /// - Returns: The current ``Task`` state.
    /// - Throws: ``A2ATransportError`` if the server returns a JSON-RPC error.
    public func getTask(_ taskId: String) async throws -> Task {
        log("Getting task: \(taskId)")
        return try await sendRPC(method: "tasks/get", params: ["id": taskId], returning: Task.self)
    }

    // MARK: - tasks/list

    /// Retrieves a list of tasks from the server using `tasks/list`.
    ///
    /// - Parameter request: Optional ``ListTasksRequest`` to filter, sort, and paginate.
    /// - Returns: A ``ListTasksResponse`` containing the task list and pagination info.
    /// - Throws: ``A2ATransportError`` if the server returns a JSON-RPC error.
    public func listTasks(_ params: ListTasksRequest? = nil) async throws -> ListTasksResponse {
        log("Listing tasks...")
        let rpcParams: [String: Any] = try params.map { try encodeProto($0) } ?? [:]
        return try await sendRPC(method: "tasks/list", params: rpcParams, returning: ListTasksResponse.self)
    }

    // MARK: - tasks/cancel

    /// Requests cancellation of an ongoing task using `tasks/cancel`.
    ///
    /// Success is not guaranteed — the task may have already completed or
    /// may not support cancellation.
    ///
    /// - Parameter taskId: The unique identifier of the task to cancel.
    /// - Returns: The updated ``Task`` state after the cancellation request.
    /// - Throws: ``A2ATransportError`` if the server returns a JSON-RPC error.
    public func cancelTask(_ taskId: String) async throws -> Task {
        log("Canceling task: \(taskId)")
        return try await sendRPC(method: "tasks/cancel", params: ["id": taskId], returning: Task.self)
    }

    // MARK: - tasks/subscribe

    /// Subscribes (or resubscribes) to an SSE stream for an ongoing task using
    /// `tasks/subscribe`.
    ///
    /// Allows a client to connect (or reconnect after a network interruption)
    /// to the event stream for a task. Subsequent ``StreamResponse`` events for
    /// the task will be emitted.
    ///
    /// - Parameter taskId: The unique identifier of the task to subscribe to.
    /// - Returns: An `AsyncThrowingStream` of ``StreamResponse`` objects.
    public func subscribeToTask(_ taskId: String) -> AsyncThrowingStream<StreamResponse, Error> {
        log("Subscribing to task: \(taskId)")

        return AsyncThrowingStream { continuation in
            let task = _Concurrency.Task {
                do {
                    let request = self.buildRequest(
                        method: "tasks/subscribe",
                        params: ["id": taskId]
                    )
                    let processed = try await self.applyRequestHandlers(request)
                    let stream = self.transport.sendStream(processed)

                    for try await data in stream {
                        let handled = try await self.applyResponseHandlers(data)
                        self.logFine("Received event from subscribe stream")

                        if handled["error"] != nil {
                            guard let errorDict = handled["error"] as? [String: Any] else {
                                continuation.finish(throwing: A2ATransportError.parsing(
                                    message: "Malformed 'error' in subscribe event"
                                ))
                                return
                            }
                            continuation.finish(throwing: transportError(from: errorDict))
                            return
                        }

                        let event = try decodeProto(StreamResponse.self, from: handled)
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - tasks/pushNotificationConfig/set

    /// Sets or updates the push notification configuration for a task.
    ///
    /// - Parameter config: The ``TaskPushNotificationConfig`` to set.
    /// - Returns: The updated ``TaskPushNotificationConfig``.
    /// - Throws: ``A2ATransportError`` if the server returns a JSON-RPC error.
    public func setPushNotificationConfig(
        _ config: TaskPushNotificationConfig
    ) async throws -> TaskPushNotificationConfig {
        log("Setting push notification config for task: \(config.taskID)")
        return try await sendRPC(
            method: "tasks/pushNotificationConfig/set",
            params: try encodeProto(config),
            returning: TaskPushNotificationConfig.self
        )
    }

    // MARK: - tasks/pushNotificationConfig/get

    /// Retrieves a specific push notification configuration for a task.
    ///
    /// - Parameters:
    ///   - taskId: The unique identifier of the task.
    ///   - configId: The unique identifier of the push notification config.
    /// - Returns: The requested ``TaskPushNotificationConfig``.
    /// - Throws: ``A2ATransportError`` if the server returns a JSON-RPC error.
    public func getPushNotificationConfig(
        taskId: String,
        configId: String
    ) async throws -> TaskPushNotificationConfig {
        log("Getting push notification config \(configId) for task: \(taskId)")
        return try await sendRPC(
            method: "tasks/pushNotificationConfig/get",
            params: ["id": taskId, "pushNotificationConfigId": configId],
            returning: TaskPushNotificationConfig.self
        )
    }

    // MARK: - tasks/pushNotificationConfig/list

    /// Lists all push notification configurations for a given task.
    ///
    /// - Parameter taskId: The unique identifier of the task.
    /// - Returns: A ``ListTaskPushNotificationConfigsResponse`` containing the configs.
    /// - Throws: ``A2ATransportError`` if the server returns a JSON-RPC error.
    public func listPushNotificationConfigs(
        taskId: String
    ) async throws -> ListTaskPushNotificationConfigsResponse {
        log("Listing push notification configs for task: \(taskId)")
        return try await sendRPC(
            method: "tasks/pushNotificationConfig/list",
            params: ["id": taskId],
            returning: ListTaskPushNotificationConfigsResponse.self
        )
    }

    // MARK: - tasks/pushNotificationConfig/delete

    /// Deletes a specific push notification configuration for a task.
    ///
    /// - Parameters:
    ///   - taskId: The unique identifier of the task.
    ///   - configId: The unique identifier of the push notification config to delete.
    /// - Throws: ``A2ATransportError`` if the server returns a JSON-RPC error.
    public func deletePushNotificationConfig(
        taskId: String,
        configId: String
    ) async throws {
        log("Deleting push notification config \(configId) for task: \(taskId)")
        try await sendRPC(
            method: "tasks/pushNotificationConfig/delete",
            params: ["id": taskId, "pushNotificationConfigId": configId]
        )
    }

    // MARK: - close

    /// Closes the underlying transport connection.
    ///
    /// Should be called when the client is no longer needed to release resources.
    public func close() {
        transport.close()
    }

    // MARK: - Private Helpers

    /// Executes a unary JSON-RPC call and decodes the `result` field into `T`.
    @discardableResult
    private func sendRPC<T: SwiftProtobuf.Message>(
        method: String,
        params: [String: Any],
        headers: [String: String] = [:],
        returning type: T.Type
    ) async throws -> T {
        let request = buildRequest(method: method, params: params)
        let processed = try await applyRequestHandlers(request)
        let response = try await transport.send(processed, headers: headers)
        let handled = try await applyResponseHandlers(response)
        logFine("Received response from \(method)")
        try throwIfError(handled)
        guard let result = handled["result"] as? [String: Any] else {
            throw A2ATransportError.parsing(message: "Missing 'result' in \(method) response")
        }
        return try decodeProto(type, from: result)
    }

    /// Executes a unary JSON-RPC call that returns no result value.
    private func sendRPC(
        method: String,
        params: [String: Any],
        headers: [String: String] = [:]
    ) async throws {
        let request = buildRequest(method: method, params: params)
        let processed = try await applyRequestHandlers(request)
        let response = try await transport.send(processed, headers: headers)
        let handled = try await applyResponseHandlers(response)
        logFine("Received response from \(method)")
        try throwIfError(handled)
    }

    /// Generates the next auto-incrementing JSON-RPC request ID (thread-safe).
    private func nextRequestId() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = requestId
        requestId += 1
        return id
    }

    /// Builds a JSON-RPC 2.0 request dictionary.
    private func buildRequest(method: String, params: [String: Any]) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": nextRequestId(),
        ]
    }

    /// Applies the handler pipeline to a request, if configured.
    private func applyRequestHandlers(_ request: [String: Any]) async throws -> [String: Any] {
        guard let pipeline = handlerPipeline else { return request }
        return try await pipeline.handleRequest(request)
    }

    /// Applies the handler pipeline to a response, if configured.
    private func applyResponseHandlers(_ response: [String: Any]) async throws -> [String: Any] {
        guard let pipeline = handlerPipeline else { return response }
        return try await pipeline.handleResponse(response)
    }

    /// Throws an ``A2ATransportError`` if the response contains an `error` key.
    private func throwIfError(_ response: [String: Any]) throws {
        guard let errorDict = response["error"] as? [String: Any] else { return }
        throw transportError(from: errorDict)
    }

    // MARK: - Logging

    private func log(_ message: String) {
        #if canImport(os)
        logger.info("\(message, privacy: .public)")
        #endif
    }

    private func logFine(_ message: String) {
        #if canImport(os)
        logger.debug("\(message, privacy: .public)")
        #endif
    }
}

// MARK: - SwiftProtobuf ↔ [String: Any] bridging

/// Encodes a SwiftProtobuf `Message` into a `[String: Any]` dictionary.
///
/// Uses SwiftProtobuf's JSON encoding for spec-correct field names
/// (camelCase, proto field name map).
private func encodeProto<T: SwiftProtobuf.Message>(_ value: T) throws -> [String: Any] {
    let jsonData = try value.jsonUTF8Data()
    guard let dict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        throw A2ATransportError.parsing(message: "Failed to encode \(T.self) to dictionary")
    }
    return dict
}

/// Decodes a `[String: Any]` dictionary into a SwiftProtobuf `Message`.
///
/// Uses SwiftProtobuf's JSON decoding for spec-correct field name handling.
private func decodeProto<T: SwiftProtobuf.Message>(_ type: T.Type, from dict: [String: Any]) throws -> T {
    let jsonData = try JSONSerialization.data(withJSONObject: dict)
    return try T(jsonUTF8Data: jsonData)
}
