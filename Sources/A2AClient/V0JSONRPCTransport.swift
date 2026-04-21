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
#if canImport(os)
import os
#endif

// MARK: - V0JSONRPCTransport
//
// An ``A2ATransport`` that speaks the A2A v0.3 JSON-RPC wire protocol.
//
// It wraps an ``SseTransport`` and intercepts each JSON-RPC 2.0 envelope to:
//   1. Map v1.0 method names / params to their v0.3 equivalents.
//   2. Re-map service-params headers (`a2a-extensions` ↔ `x-a2a-extensions`).
//   3. Convert v0.3 responses back to v1.0 proto-compatible dicts before
//      returning them to ``A2AClient``.
//
// Mirrors Go's `V0JSONRPCTransport` in `a2acompat/a2av0/transport.go`.

/// A transport that communicates with a v0.3 A2A server over JSON-RPC.
///
/// Drop in a ``V0JSONRPCTransport`` anywhere an ``A2ATransport`` is expected to
/// talk to older servers.  ``A2ATransportFactory`` can select this transport
/// automatically when the ``AgentCard/supportedInterfaces`` indicates a
/// `protocolVersion` of `"0.3"`.
///
/// ## Example
///
/// ```swift
/// let transport = V0JSONRPCTransport(url: "https://old-agent.example.com")
/// let client = A2AClient(url: "https://old-agent.example.com", transport: transport)
/// ```
public final class V0JSONRPCTransport: A2ATransport, @unchecked Sendable {

    // MARK: - Properties

    /// The base URL of the v0.3 A2A server.
    public let url: String

    /// Auth params forwarded to every request.
    public let authParams: ServiceParams

    /// The underlying SSE/HTTP transport.
    private let inner: SseTransport

    private let sseParser = SseParser()

    #if canImport(os)
    private let logger = Logger(subsystem: "A2UIV09_A2A", category: "V0JSONRPCTransport")
    #endif

    // MARK: - v0.3 method name overrides

    /// v0.3 uses a different name for the extended card method.
    private static let methodGetExtendedAgentCard = "agent/getAuthenticatedExtendedCard"

    // MARK: - Initialisers

    /// Creates a ``V0JSONRPCTransport``.
    ///
    /// - Parameters:
    ///   - url: The base URL of the v0.3 A2A server.
    ///   - authParams: Optional service params (e.g. auth headers) for every request.
    ///   - session: Optional `URLSession` for custom configurations or testing.
    public init(
        url: String,
        authParams: ServiceParams = ServiceParams(),
        session: URLSession = .shared
    ) {
        self.url = url
        self.authParams = authParams
        self.inner = SseTransport(url: url, authParams: authParams, session: session)
    }

    // MARK: - A2ATransport – get (AgentCard)

    /// Fetches the agent card at `path`, parsing v0.3 or v1.0 card JSON.
    public func get(path: String, params: ServiceParams = ServiceParams()) async throws -> [String: Any] {
        // Remap headers for v0.3 (a2a-extensions → x-a2a-extensions).
        let v0Params = fromServiceParams(params)
        let dict = try await inner.get(path: path, params: v0Params)
        // AgentCard is returned as-is; `parseV0AgentCard` lives on the
        // `AgentCardResolver` layer — we just return the raw dict here and
        // let the caller decode it.  If the caller is `AgentCardResolver`
        // it will call `parseV0AgentCard` itself.  If the caller is
        // `HttpTransport.get` it already received a dict.
        // We re-encode the card into a v1-compatible dict if needed:
        let card = try parseV0AgentCard(from: dict)
        return try encodeProtoToDict(card)
    }

    // MARK: - A2ATransport – send (non-streaming)

    /// Converts a v1.0 JSON-RPC 2.0 envelope to v0.3, sends it, and converts
    /// the v0.3 response back to a v1.0-compatible JSON-RPC 2.0 envelope.
    public func send(
        _ request: [String: Any],
        path: String = "",
        params: ServiceParams = ServiceParams()
    ) async throws -> [String: Any] {
        let (v0Request, v0Params) = try convertRequest(request, params: params)

        #if canImport(os)
        logger.debug("V0 send: \(v0Request["method"] as? String ?? "<unknown>", privacy: .public)")
        #endif

        let v0Response = try await inner.send(v0Request, path: path, params: v0Params)
        return try convertResponse(v0Response, method: request["method"] as? String)
    }

    // MARK: - A2ATransport – sendStream (SSE)

    /// Converts a v1.0 JSON-RPC 2.0 streaming request to v0.3 and maps each
    /// incoming v0.3 SSE event to a v1.0-compatible ``StreamResponse`` dict.
    public func sendStream(
        _ request: [String: Any],
        params: ServiceParams = ServiceParams()
    ) -> AsyncThrowingStream<[String: Any], Error> {
        let (stream, continuation) = AsyncThrowingStream<[String: Any], Error>.makeStream()

        let convertedRequest: [String: Any]
        let v0Params: ServiceParams
        do {
            (convertedRequest, v0Params) = try convertRequest(request, params: params)
        } catch {
            continuation.finish(throwing: error)
            return stream
        }

        #if canImport(os)
        let log = logger
        #endif

        let innerTransport = inner

        let task = _Concurrency.Task {
            let rawStream = innerTransport.sendStream(convertedRequest, params: v0Params)
            do {
                for try await eventDict in rawStream {
                    // Each SSE event from a v0.3 server is a raw JSON-RPC
                    // result object (no jsonrpc/id envelope); we may receive
                    // either a TaskStatusUpdateEvent or a TaskArtifactUpdateEvent.
                    //
                    // If the event has an "error" key it is a JSON-RPC error
                    // envelope; pass it through unchanged so the client can handle it.
                    if eventDict["error"] != nil {
                        continuation.yield(eventDict)
                        continue
                    }

                    if let streamResult = decodeV0StreamEvent(eventDict) {
                        let v1Dict = try streamEventToDict(streamResult)
                        continuation.yield(v1Dict)
                    } else {
                        // Unknown event shape — pass through as-is.
                        #if canImport(os)
                        log.debug("V0 stream: unknown event shape, passing through")
                        #endif
                        continuation.yield(eventDict)
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - A2ATransport – close

    public func close() {
        inner.close()
    }

    // MARK: - Request conversion

    /// Converts a v1.0 JSON-RPC 2.0 request envelope to its v0.3 equivalent.
    ///
    /// Returns the converted request dict and the remapped service params.
    private func convertRequest(
        _ request: [String: Any],
        params: ServiceParams
    ) throws -> ([String: Any], ServiceParams) {
        guard let method = request["method"] as? String else {
            throw A2ATransportError.parsing(message: "JSON-RPC request missing 'method'")
        }

        let v0Method = v0MethodName(for: method)
        let rawParams = request["params"] as? [String: Any] ?? [:]
        let v0Params = try convertParams(method: method, params: rawParams)

        var v0Request = request
        v0Request["method"] = v0Method
        v0Request["params"] = v0Params

        // tasks/list is not supported in v0.3.
        if method == "tasks/list" {
            throw A2ATransportError.unsupportedOperation(
                message: "tasks/list is not supported by v0.3 servers"
            )
        }

        let v0ServiceParams = fromServiceParams(params)
        return (v0Request, v0ServiceParams)
    }

    /// Maps a v1.0 method name to its v0.3 equivalent (if different).
    private func v0MethodName(for method: String) -> String {
        switch method {
        case "agent/authenticatedExtendedCard":
            return Self.methodGetExtendedAgentCard
        default:
            return method
        }
    }

    /// Converts v1.0 JSON-RPC params to the v0.3 wire format for a given method.
    private func convertParams(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "message/send", "message/stream":
            return try convertSendMessageParams(params)

        case "tasks/get":
            // v0.3: { id, historyLength? }
            // v1.0: GetTaskRequest { taskId, historyLength? }
            var v0: [String: Any] = [:]
            if let id = params["taskId"] as? String { v0["id"] = id }
            if let hl = params["historyLength"] { v0["historyLength"] = hl }
            return v0

        case "tasks/cancel":
            // v0.3: { id }
            // v1.0: CancelTaskRequest { taskId }
            var v0: [String: Any] = [:]
            if let id = params["taskId"] as? String { v0["id"] = id }
            return v0

        case "tasks/subscribe":
            // v0.3: tasks/resubscribe { id }
            // v1.0: SubscribeToTaskRequest { taskId }
            var v0: [String: Any] = [:]
            if let id = params["taskId"] as? String { v0["id"] = id }
            return v0

        case "tasks/pushNotificationConfig/set":
            // v0.3: { id, pushNotificationConfig }
            return try convertSetPushConfigParams(params)

        case "tasks/pushNotificationConfig/get":
            // v0.3: { id }
            var v0: [String: Any] = [:]
            if let id = params["taskId"] as? String ?? params["id"] as? String { v0["id"] = id }
            return v0

        case "tasks/pushNotificationConfig/delete":
            // v0.3 doesn't support per-config delete, use id only
            var v0: [String: Any] = [:]
            if let id = params["taskId"] as? String ?? params["id"] as? String { v0["id"] = id }
            return v0

        default:
            // Pass through as-is for unknown methods.
            return params
        }
    }

    /// Converts v1.0 `SendMessageRequest` params to v0.3 `V0MessageSendParams`.
    private func convertSendMessageParams(_ params: [String: Any]) throws -> [String: Any] {
        // Decode the SendMessageRequest proto from the params dict.
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let req = try? SendMessageRequest(jsonUTF8Data: data)
        else {
            // Fallback: pass through unchanged.
            return params
        }
        let v0 = fromV1SendMessageRequest(req)
        let encoder = JSONEncoder()
        guard let encodedData = try? encoder.encode(v0),
              let dict = try? JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
        else {
            throw A2ATransportError.parsing(message: "Failed to encode V0MessageSendParams")
        }
        return dict
    }

    /// Converts v1.0 push config params to v0.3.
    private func convertSetPushConfigParams(_ params: [String: Any]) throws -> [String: Any] {
        // v1.0 TaskPushNotificationConfig: { id, taskId, pushNotificationConfig }
        // v0.3: { id, pushNotificationConfig }
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let config = try? TaskPushNotificationConfig(jsonUTF8Data: data)
        else {
            return params
        }
        let v0 = fromV1TaskPushConfig(config)
        let encoder = JSONEncoder()
        guard let encodedData = try? encoder.encode(v0),
              let dict = try? JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
        else {
            throw A2ATransportError.parsing(message: "Failed to encode V0TaskPushNotificationConfig")
        }
        return dict
    }

    // MARK: - Response conversion

    /// Converts a v0.3 JSON-RPC 2.0 response envelope back to v1.0.
    ///
    /// If the response contains an `error` key it is returned unchanged so the
    /// client's error-mapping logic can handle it.  Otherwise, the `result`
    /// field is decoded from its v0.3 shape and re-encoded in v1.0 form.
    private func convertResponse(_ response: [String: Any], method: String?) throws -> [String: Any] {
        // Pass error responses through as-is.
        if response["error"] != nil { return response }

        guard let result = response["result"] as? [String: Any] else {
            // No result object (e.g. void responses); return as-is.
            return response
        }

        var converted = response
        converted["result"] = try convertResult(result, method: method)
        return converted
    }

    /// Converts the `result` dict from v0.3 shape to v1.0 shape.
    private func convertResult(_ result: [String: Any], method: String?) throws -> [String: Any] {
        switch method {
        case "message/send":
            // v0.3 returns either a V0Task or a V0Message.
            return try convertSendMessageResult(result)

        case "tasks/get", "tasks/cancel":
            return try convertTask(result)

        case "tasks/pushNotificationConfig/set",
             "tasks/pushNotificationConfig/get":
            return try convertPushConfig(result)

        case "agent/authenticatedExtendedCard",
             "agent/getAuthenticatedExtendedCard":
            // AgentCard — parse with v0.3 compat, re-encode as v1.0.
            let card = try parseV0AgentCard(from: result)
            return try encodeProtoToDict(card)

        default:
            return result
        }
    }

    /// Converts a v0.3 `message/send` result (V0Task or V0Message) to v1.0
    /// `SendMessageResponse` shape.
    private func convertSendMessageResult(_ result: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: result)

        // If the result has a "status" field it is a V0Task; otherwise V0Message.
        if result["status"] != nil {
            guard let v0Task = try? JSONDecoder().decode(V0Task.self, from: data) else {
                return result
            }
            let v1Task = toV1Task(v0Task)
            var resp = SendMessageResponse()
            resp.task = v1Task
            return try encodeProtoToDict(resp)
        } else if result["parts"] != nil || result["messageId"] != nil {
            guard let v0Msg = try? JSONDecoder().decode(V0Message.self, from: data) else {
                return result
            }
            let v1Msg = toV1Message(v0Msg)
            var resp = SendMessageResponse()
            resp.message = v1Msg
            return try encodeProtoToDict(resp)
        }

        return result
    }

    /// Converts a v0.3 V0Task dict to a v1.0 Task dict.
    private func convertTask(_ result: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: result)
        guard let v0Task = try? JSONDecoder().decode(V0Task.self, from: data) else {
            return result
        }
        return try encodeProtoToDict(toV1Task(v0Task))
    }

    /// Converts a v0.3 V0TaskPushNotificationConfig dict to v1.0.
    private func convertPushConfig(_ result: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: result)
        guard let v0Cfg = try? JSONDecoder().decode(V0TaskPushNotificationConfig.self, from: data) else {
            return result
        }
        return try encodeProtoToDict(toV1TaskPushConfig(v0Cfg))
    }

    // MARK: - Streaming event conversion

    /// Converts a ``StreamEventResult`` (from ``decodeV0StreamEvent``) to a
    /// v1.0 JSON-RPC 2.0-compatible result dict (as ``StreamResponse``).
    private func streamEventToDict(_ result: StreamEventResult) throws -> [String: Any] {
        var streamResp = StreamResponse()
        switch result {
        case .statusUpdate(let ev):
            streamResp.statusUpdate = ev
        case .artifactUpdate(let ev):
            streamResp.artifactUpdate = ev
        case .message(let msg):
            streamResp.message = msg
        }
        return try encodeProtoToDict(streamResp)
    }

    // MARK: - Helpers

    /// Encodes a SwiftProtobuf message to a `[String: Any]` dictionary via JSON.
    private func encodeProtoToDict<T: SwiftProtobuf.Message>(_ value: T) throws -> [String: Any] {
        let jsonData = try value.jsonUTF8Data()
        guard let dict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw A2ATransportError.parsing(
                message: "Failed to encode \(T.protoMessageName) to dict"
            )
        }
        return dict
    }
}
