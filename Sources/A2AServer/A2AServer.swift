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

// MARK: - ServerRequest

/// A framework-agnostic description of an incoming HTTP request.
///
/// Callers (Vapor, Hummingbird, NIO, etc.) convert their framework request
/// into a ``ServerRequest`` and pass it to ``A2AServer/handle(_:)``.
public struct ServerRequest: Sendable {
    /// HTTP method (e.g. `"GET"`, `"POST"`).
    public var method: String
    /// URL path (e.g. `"/.well-known/agent.json"`, `"/"`).
    public var path: String
    /// Request headers (lowercase names).
    public var headers: [String: String]
    /// Raw request body, or `nil` for GET requests.
    public var body: Data?
    /// URL query parameters, if any.
    public var queryItems: [String: String]

    public init(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        queryItems: [String: String] = [:]
    ) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.queryItems = queryItems
    }
}

// MARK: - ServerResponse

/// A framework-agnostic HTTP response.
public struct ServerResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data?

    public init(statusCode: Int, headers: [String: String] = [:], body: Data? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Creates a 200 OK JSON response.
    static func ok(json body: Data) -> ServerResponse {
        ServerResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    /// Creates a JSON-RPC error response.
    static func jsonRPCError(id: JSONRPCValue?, code: Int, message: String) -> ServerResponse {
        let body = JSONRPCResponse.error(id: id, code: code, message: message)
        return ServerResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: try? JSONSerialization.data(withJSONObject: body)
        )
    }
}

// MARK: - SSEStream

/// A server-sent-events (SSE) stream.
///
/// Each string in `lines` is a complete SSE frame, e.g.:
/// ```
/// data: {"jsonrpc":"2.0","result":{...}}\n\n
/// ```
public struct SSEStream: Sendable {
    public var lines: AsyncThrowingStream<String, Error>
    public init(lines: AsyncThrowingStream<String, Error>) {
        self.lines = lines
    }
}

// MARK: - ServerResult

/// The result of dispatching an ``A2AServer`` request.
public enum ServerResult: Sendable {
    /// A regular HTTP response.
    case response(ServerResponse)
    /// A server-sent-events stream (for streaming methods).
    case stream(SSEStream)
}

// MARK: - JSONRPCValue (internal)

/// A JSON-RPC request/response `id` field (string or integer).
enum JSONRPCValue: Sendable {
    case string(String)
    case int(Int)
    case null
}

// MARK: - JSONRPCResponse (internal helper)

enum JSONRPCResponse {
    /// Builds a JSON-RPC success envelope.
    static func success(id: JSONRPCValue?, result: Any) -> [String: Any] {
        var dict: [String: Any] = ["jsonrpc": "2.0"]
        dict["id"] = jsonID(id)
        dict["result"] = result
        return dict
    }

    /// Builds a JSON-RPC error envelope.
    static func error(id: JSONRPCValue?, code: Int, message: String, data: Any? = nil) -> [String: Any] {
        var errorDict: [String: Any] = ["code": code, "message": message]
        if let data { errorDict["data"] = data }
        var dict: [String: Any] = ["jsonrpc": "2.0"]
        dict["id"] = jsonID(id)
        dict["error"] = errorDict
        return dict
    }

    private static func jsonID(_ id: JSONRPCValue?) -> Any {
        switch id {
        case .string(let s): return s
        case .int(let i):    return i
        case .null, nil:     return NSNull()
        }
    }
}

// MARK: - A2AServer

/// Routes incoming HTTP requests to the appropriate ``RequestHandler`` method
/// and serialises responses as JSON-RPC 2.0.
///
/// ## Framework integration
///
/// ``A2AServer`` is intentionally framework-agnostic.  Convert your HTTP
/// framework's request type to ``ServerRequest`` and call ``handle(_:)``:
///
/// ```swift
/// // Pseudo-code — swap in your actual framework:
/// app.post("/") { req async in
///     let serverReq = ServerRequest(method: "POST", path: "/",
///                                   headers: req.headers, body: req.body)
///     switch await server.handle(serverReq) {
///     case .response(let r): return Response(status: r.statusCode, body: r.body)
///     case .stream(let s):   return streamSSE(s.lines)
///     }
/// }
/// ```
///
/// Mirrors Go's `jsonrpcHandler` in `a2asrv/jsonrpc.go`.
public final class A2AServer: Sendable {

    // MARK: - Properties

    /// The ``RequestHandler`` that processes business logic.
    public let handler: any RequestHandler
    /// The public ``AgentCard`` served at ``cardPath``.
    public let agentCard: AgentCard
    /// The URL path from which the agent card is served.
    ///
    /// Defaults to `/.well-known/agent.json`.
    public let cardPath: String

    // MARK: - Initialiser

    /// Creates an ``A2AServer``.
    ///
    /// - Parameters:
    ///   - handler: The request handler.
    ///   - agentCard: The agent card to expose.
    ///   - cardPath: URL path for the agent card endpoint.
    public init(
        handler: any RequestHandler,
        agentCard: AgentCard,
        cardPath: String = "/.well-known/agent.json"
    ) {
        self.handler = handler
        self.agentCard = agentCard
        self.cardPath = cardPath
    }

    // MARK: - Dispatch

    /// Dispatch an incoming request to the appropriate handler.
    ///
    /// - Returns: Either a ``ServerResult/response(_:)`` or a
    ///   ``ServerResult/stream(_:)`` for SSE endpoints.
    public func handle(_ request: ServerRequest) async -> ServerResult {
        // 1. Agent card.
        if request.method.uppercased() == "GET" && request.path == cardPath {
            return handleAgentCard()
        }

        // 2. Require POST for JSON-RPC.
        guard request.method.uppercased() == "POST" else {
            return .response(ServerResponse.jsonRPCError(id: nil, code: -32_600, message: "Method not allowed"))
        }

        // 3. Parse JSON-RPC envelope.
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return .response(ServerResponse.jsonRPCError(id: nil, code: -32_700, message: "Parse error"))
        }

        let rpcID = parseID(json["id"])
        guard let method = json["method"] as? String else {
            return .response(ServerResponse.jsonRPCError(id: rpcID, code: -32_600, message: "Invalid Request: missing method"))
        }

        let params = json["params"] as? [String: Any] ?? [:]

        // 4. Route to handler method.
        return await dispatch(method: method, params: params, id: rpcID)
    }

    // MARK: - Private routing

    private func dispatch(method: String, params: [String: Any], id: JSONRPCValue?) async -> ServerResult {
        switch method {
        case "tasks/get":
            return await handleGetTask(params: params, id: id)
        case "tasks/list":
            return await handleListTasks(params: params, id: id)
        case "tasks/cancel":
            return await handleCancelTask(params: params, id: id)
        case "message/send":
            return await handleSendMessage(params: params, id: id)
        case "message/stream":
            return handleStreamingMessage(params: params, id: id)
        case "tasks/resubscribe":
            return handleSubscribeToTask(params: params, id: id)
        case "tasks/pushNotificationConfig/get":
            return await handleGetPushConfig(params: params, id: id)
        case "tasks/pushNotificationConfig/list":
            return await handleListPushConfigs(params: params, id: id)
        case "tasks/pushNotificationConfig/set":
            return await handleCreatePushConfig(params: params, id: id)
        case "tasks/pushNotificationConfig/delete":
            return await handleDeletePushConfig(params: params, id: id)
        case "agent/authenticatedExtendedCard":
            return await handleGetExtendedCard(params: params, id: id)
        default:
            return .response(ServerResponse.jsonRPCError(id: id, code: -32_601, message: "Method not found: \(method)"))
        }
    }

    // MARK: - Agent card

    private func handleAgentCard() -> ServerResult {
        guard let data = try? agentCard.jsonUTF8Data() else {
            return .response(ServerResponse(statusCode: 500))
        }
        return .response(ServerResponse.ok(json: data))
    }

    // MARK: - tasks/get

    private func handleGetTask(params: [String: Any], id: JSONRPCValue?) async -> ServerResult {
        do {
            let req = try decodeProto(GetTaskRequest.self, from: params)
            let task = try await handler.getTask(req)
            return try rpcSuccess(id: id, value: task)
        } catch {
            return rpcError(id: id, error: error)
        }
    }

    // MARK: - tasks/list

    private func handleListTasks(params: [String: Any], id: JSONRPCValue?) async -> ServerResult {
        do {
            let req = try decodeProto(ListTasksRequest.self, from: params)
            let resp = try await handler.listTasks(req)
            return try rpcSuccess(id: id, value: resp)
        } catch {
            return rpcError(id: id, error: error)
        }
    }

    // MARK: - tasks/cancel

    private func handleCancelTask(params: [String: Any], id: JSONRPCValue?) async -> ServerResult {
        do {
            let req = try decodeProto(CancelTaskRequest.self, from: params)
            let task = try await handler.cancelTask(req)
            return try rpcSuccess(id: id, value: task)
        } catch {
            return rpcError(id: id, error: error)
        }
    }

    // MARK: - message/send

    private func handleSendMessage(params: [String: Any], id: JSONRPCValue?) async -> ServerResult {
        do {
            let req = try decodeProto(SendMessageRequest.self, from: params)
            let resp = try await handler.sendMessage(req)
            return try rpcSuccess(id: id, value: resp)
        } catch {
            return rpcError(id: id, error: error)
        }
    }

    // MARK: - message/stream (SSE)

    private func handleStreamingMessage(params: [String: Any], id: JSONRPCValue?) -> ServerResult {
        guard let req = try? decodeProto(SendMessageRequest.self, from: params) else {
            return .response(ServerResponse.jsonRPCError(id: id, code: -32_600, message: "Invalid params"))
        }
        let eventStream = handler.sendStreamingMessage(req)
        return makeSSEStream(id: id, events: eventStream)
    }

    // MARK: - tasks/resubscribe (SSE)

    private func handleSubscribeToTask(params: [String: Any], id: JSONRPCValue?) -> ServerResult {
        guard let req = try? decodeProto(SubscribeToTaskRequest.self, from: params) else {
            return .response(ServerResponse.jsonRPCError(id: id, code: -32_600, message: "Invalid params"))
        }
        let eventStream = handler.subscribeToTask(req)
        return makeSSEStream(id: id, events: eventStream)
    }

    // MARK: - Push config methods

    private func handleGetPushConfig(params: [String: Any], id: JSONRPCValue?) async -> ServerResult {
        do {
            let req = try decodeProto(GetTaskPushNotificationConfigRequest.self, from: params)
            let config = try await handler.getTaskPushConfig(req)
            return try rpcSuccess(id: id, value: config)
        } catch {
            return rpcError(id: id, error: error)
        }
    }

    private func handleListPushConfigs(params: [String: Any], id: JSONRPCValue?) async -> ServerResult {
        do {
            let req = try decodeProto(ListTaskPushNotificationConfigsRequest.self, from: params)
            let configs = try await handler.listTaskPushConfigs(req)
            // Build response envelope.
            var resp = ListTaskPushNotificationConfigsResponse()
            resp.configs = configs
            return try rpcSuccess(id: id, value: resp)
        } catch {
            return rpcError(id: id, error: error)
        }
    }

    private func handleCreatePushConfig(params: [String: Any], id: JSONRPCValue?) async -> ServerResult {
        do {
            let config = try decodeProto(TaskPushNotificationConfig.self, from: params)
            let saved = try await handler.createTaskPushConfig(config)
            return try rpcSuccess(id: id, value: saved)
        } catch {
            return rpcError(id: id, error: error)
        }
    }

    private func handleDeletePushConfig(params: [String: Any], id: JSONRPCValue?) async -> ServerResult {
        do {
            let req = try decodeProto(DeleteTaskPushNotificationConfigRequest.self, from: params)
            try await handler.deleteTaskPushConfig(req)
            return try rpcSuccess(id: id, value: [String: Any]())
        } catch {
            return rpcError(id: id, error: error)
        }
    }

    // MARK: - Extended card

    private func handleGetExtendedCard(params: [String: Any], id: JSONRPCValue?) async -> ServerResult {
        do {
            let req = try decodeProto(GetExtendedAgentCardRequest.self, from: params)
            let card = try await handler.getExtendedAgentCard(req)
            return try rpcSuccess(id: id, value: card)
        } catch {
            return rpcError(id: id, error: error)
        }
    }

    // MARK: - SSE helpers

    private func makeSSEStream(id: JSONRPCValue?, events: AsyncThrowingStream<AgentEvent, Error>) -> ServerResult {
        let lines = AsyncThrowingStream<String, Error> { continuation in
            _Concurrency.Task {
                do {
                    for try await event in events {
                        // Wrap event in a StreamResponse and encode to JSON.
                        let responseJSON = try sseFrame(for: event, id: id)
                        continuation.yield(responseJSON)
                        if event.isFinal { break }
                    }
                    continuation.finish()
                } catch {
                    let errorFrame = sseErrorFrame(id: id, error: error)
                    continuation.yield(errorFrame)
                    continuation.finish()
                }
            }
        }
        return .stream(SSEStream(lines: lines))
    }

    private func sseFrame(for event: AgentEvent, id: JSONRPCValue?) throws -> String {
        let json = try agentEventToJSON(event)
        let envelope = JSONRPCResponse.success(id: id, result: json)
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let jsonStr = String(data: data, encoding: .utf8) ?? "{}"
        return "data: \(jsonStr)\n\n"
    }

    private func sseErrorFrame(id: JSONRPCValue?, error: Error) -> String {
        let (code, message) = errorCodeAndMessage(error)
        let envelope = JSONRPCResponse.error(id: id, code: code, message: message)
        let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        let jsonStr = String(data: data, encoding: .utf8) ?? "{}"
        return "data: \(jsonStr)\n\n"
    }

    // MARK: - Serialisation helpers

    private func rpcSuccess<T: SwiftProtobuf.Message>(id: JSONRPCValue?, value: T) throws -> ServerResult {
        let dict = try encodeProto(value)
        let envelope = JSONRPCResponse.success(id: id, result: dict)
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return .response(ServerResponse.ok(json: data))
    }

    private func rpcSuccess(id: JSONRPCValue?, value: [String: Any]) throws -> ServerResult {
        let envelope = JSONRPCResponse.success(id: id, result: value)
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return .response(ServerResponse.ok(json: data))
    }

    private func rpcError(id: JSONRPCValue?, error: Error) -> ServerResult {
        let (code, message) = errorCodeAndMessage(error)
        return .response(ServerResponse.jsonRPCError(id: id, code: code, message: message))
    }

    private func errorCodeAndMessage(_ error: Error) -> (Int, String) {
        switch error {
        case let e as A2AServerError:
            return (e.jsonRPCCode, "\(e)")
        case TaskStoreError.taskNotFound:
            return (A2AServerError.taskNotFound.jsonRPCCode, "Task not found")
        case TaskStoreError.concurrentModification:
            return (A2AServerError.internalError(message: "").jsonRPCCode, "Concurrent modification")
        case let e as PushError:
            return (A2AServerError.internalError(message: "").jsonRPCCode, "\(e)")
        default:
            return (-32_000, error.localizedDescription)
        }
    }

    private func parseID(_ value: Any?) -> JSONRPCValue? {
        switch value {
        case let s as String: return .string(s)
        case let i as Int:    return .int(i)
        default:              return .null
        }
    }

    /// Convert ``AgentEvent`` to a JSON-compatible `[String: Any]`.
    private func agentEventToJSON(_ event: AgentEvent) throws -> [String: Any] {
        switch event {
        case .task(let t):           return try encodeProto(t)
        case .message(let m):        return try encodeProto(m)
        case .statusUpdate(let e):   return try encodeProto(e)
        case .artifactUpdate(let e): return try encodeProto(e)
        }
    }
}

// MARK: - Proto encode/decode helpers (file-private)

private func encodeProto<T: SwiftProtobuf.Message>(_ value: T) throws -> [String: Any] {
    let jsonString = try value.jsonString()
    guard let data = jsonString.data(using: .utf8),
          let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw A2AServerError.internalError(message: "Failed to encode \(T.self) to JSON")
    }
    return dict
}

private func decodeProto<T: SwiftProtobuf.Message>(_ type: T.Type, from dict: [String: Any]) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: dict)
    guard let jsonString = String(data: data, encoding: .utf8) else {
        throw A2AServerError.invalidParams(message: "Failed to decode \(T.self) from JSON")
    }
    return try T(jsonString: jsonString)
}
