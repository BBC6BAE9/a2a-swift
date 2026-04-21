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
#if canImport(os)
import os
#endif

// MARK: - RestTransport

/// An ``A2ATransport`` implementation that communicates with an A2A server
/// using REST HTTP endpoints instead of JSON-RPC.
///
/// Incoming calls use the JSON-RPC envelope format (a `[String: Any]`
/// dictionary with `method` and `params` keys) because that is what
/// ``A2AClient`` always produces.  ``RestTransport`` extracts the `method`
/// field, maps it to the appropriate REST endpoint and HTTP verb, executes
/// the request, then wraps the HTTP response body back into a JSON-RPC
/// `result` envelope so the client can decode it transparently.
///
/// ## Method → REST path mapping
///
/// | JSON-RPC method                       | HTTP     | REST path                                  |
/// |---------------------------------------|----------|--------------------------------------------|
/// | `message/send`                        | POST     | `/messages:send`                           |
/// | `message/stream`                      | POST     | `/messages:stream`  (SSE)                  |
/// | `tasks/get`                           | GET      | `/tasks/{id}`                              |
/// | `tasks/list`                          | GET      | `/tasks`                                   |
/// | `tasks/cancel`                        | POST     | `/tasks/{id}:cancel`                       |
/// | `tasks/subscribe`                     | POST     | `/tasks/{id}:subscribe`  (SSE)             |
/// | `tasks/pushNotificationConfig/set`    | POST     | `/tasks/{taskId}/pushConfigs`              |
/// | `tasks/pushNotificationConfig/get`    | GET      | `/tasks/{taskId}/pushConfigs/{id}`         |
/// | `tasks/pushNotificationConfig/list`   | GET      | `/tasks/{taskId}/pushConfigs`              |
/// | `tasks/pushNotificationConfig/delete` | DELETE   | `/tasks/{taskId}/pushConfigs/{id}`         |
/// | `getExtendedAgentCard`                | GET      | `/extendedAgentCard`                       |
///
/// Mirrors Go's `RESTTransport` in `a2aclient/rest.go`.
public final class RestTransport: A2ATransport, @unchecked Sendable {

    // MARK: - Properties

    /// The base URL of the A2A server (e.g. `https://agent.example.com`).
    public let url: String

    /// Additional service parameters (e.g. auth headers) added to every request.
    public let authParams: ServiceParams

    /// The `URLSession` used for HTTP requests.
    public let session: URLSession

    #if canImport(os)
    private let logger = Logger(subsystem: "A2UIV09_A2A", category: "RestTransport")
    #endif

    // MARK: - Initialiser

    /// Creates a ``RestTransport`` instance.
    ///
    /// - Parameters:
    ///   - url: The base URL of the A2A server.
    ///   - authParams: Optional service params (e.g. auth headers) for every request.
    ///   - session: Optional `URLSession` for custom configurations or testing.
    public init(
        url: String,
        authParams: ServiceParams = ServiceParams(),
        session: URLSession = .shared
    ) {
        self.url = url
        self.authParams = authParams
        self.session = session
    }

    // MARK: - A2ATransport: get

    public func get(path: String, params: ServiceParams) async throws -> [String: Any] {
        guard let requestURL = URL(string: "\(url)\(path)") else {
            throw A2ATransportError.network(message: "Invalid URL: \(url)\(path)")
        }
        return try await executeGet(url: requestURL, extraParams: params)
    }

    // MARK: - A2ATransport: send

    public func send(
        _ request: [String: Any],
        path: String,
        params: ServiceParams
    ) async throws -> [String: Any] {
        guard let method = request["method"] as? String else {
            throw A2ATransportError.parsing(message: "REST transport: missing 'method' in request")
        }
        let rpcParams = request["params"] as? [String: Any] ?? [:]

        switch method {

        // ── Message ────────────────────────────────────────────────────────────

        case "message/send":
            let restURL = try buildURL(path: "/messages:send")
            let body = rpcParams
            let responseBody = try await executePost(url: restURL, body: body, extraParams: params)
            return wrapResult(responseBody, id: request["id"])

        // ── Tasks ──────────────────────────────────────────────────────────────

        case "tasks/get":
            guard let id = rpcParams["id"] as? String, !id.isEmpty else {
                throw A2ATransportError.parsing(message: "REST transport: 'tasks/get' requires 'id' param")
            }
            let restURL = try buildURL(path: "/tasks/\(id)")
            let responseBody = try await executeGet(url: restURL, extraParams: params)
            return wrapResult(responseBody, id: request["id"])

        case "tasks/list":
            var queryItems: [URLQueryItem] = []
            if let contextId = rpcParams["contextId"] as? String, !contextId.isEmpty {
                queryItems.append(URLQueryItem(name: "contextId", value: contextId))
            }
            if let status = rpcParams["status"] as? String, !status.isEmpty {
                queryItems.append(URLQueryItem(name: "status", value: status))
            }
            if let pageSize = rpcParams["pageSize"] as? Int {
                queryItems.append(URLQueryItem(name: "pageSize", value: String(pageSize)))
            }
            if let pageToken = rpcParams["pageToken"] as? String, !pageToken.isEmpty {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let restURL = try buildURL(path: "/tasks", queryItems: queryItems)
            let responseBody = try await executeGet(url: restURL, extraParams: params)
            return wrapResult(responseBody, id: request["id"])

        case "tasks/cancel":
            guard let id = rpcParams["id"] as? String, !id.isEmpty else {
                throw A2ATransportError.parsing(message: "REST transport: 'tasks/cancel' requires 'id' param")
            }
            let restURL = try buildURL(path: "/tasks/\(id):cancel")
            let body = rpcParams
            let responseBody = try await executePost(url: restURL, body: body, extraParams: params)
            return wrapResult(responseBody, id: request["id"])

        // ── Push notification configs ──────────────────────────────────────────

        case "tasks/pushNotificationConfig/set":
            guard let taskId = rpcParams["taskId"] as? String, !taskId.isEmpty else {
                throw A2ATransportError.parsing(
                    message: "REST transport: 'tasks/pushNotificationConfig/set' requires 'taskId' param"
                )
            }
            let restURL = try buildURL(path: "/tasks/\(taskId)/pushConfigs")
            let body = rpcParams
            let responseBody = try await executePost(url: restURL, body: body, extraParams: params)
            return wrapResult(responseBody, id: request["id"])

        case "tasks/pushNotificationConfig/get":
            guard let taskId = rpcParams["taskId"] as? String, !taskId.isEmpty else {
                throw A2ATransportError.parsing(
                    message: "REST transport: 'tasks/pushNotificationConfig/get' requires 'taskId' param"
                )
            }
            guard let configId = rpcParams["id"] as? String, !configId.isEmpty else {
                throw A2ATransportError.parsing(
                    message: "REST transport: 'tasks/pushNotificationConfig/get' requires 'id' param"
                )
            }
            let restURL = try buildURL(path: "/tasks/\(taskId)/pushConfigs/\(configId)")
            let responseBody = try await executeGet(url: restURL, extraParams: params)
            return wrapResult(responseBody, id: request["id"])

        case "tasks/pushNotificationConfig/list":
            guard let taskId = rpcParams["taskId"] as? String, !taskId.isEmpty else {
                throw A2ATransportError.parsing(
                    message: "REST transport: 'tasks/pushNotificationConfig/list' requires 'taskId' param"
                )
            }
            let restURL = try buildURL(path: "/tasks/\(taskId)/pushConfigs")
            let responseBody = try await executeGet(url: restURL, extraParams: params)
            return wrapResult(responseBody, id: request["id"])

        case "tasks/pushNotificationConfig/delete":
            guard let taskId = rpcParams["taskId"] as? String, !taskId.isEmpty else {
                throw A2ATransportError.parsing(
                    message: "REST transport: 'tasks/pushNotificationConfig/delete' requires 'taskId' param"
                )
            }
            guard let configId = rpcParams["id"] as? String, !configId.isEmpty else {
                throw A2ATransportError.parsing(
                    message: "REST transport: 'tasks/pushNotificationConfig/delete' requires 'id' param"
                )
            }
            let restURL = try buildURL(path: "/tasks/\(taskId)/pushConfigs/\(configId)")
            let responseBody = try await executeDelete(url: restURL, extraParams: params)
            return wrapResult(responseBody, id: request["id"])

        // ── Extended agent card ────────────────────────────────────────────────

        case "getExtendedAgentCard":
            let restURL = try buildURL(path: A2AClient.extendedAgentCardPath)
            let responseBody = try await executeGet(url: restURL, extraParams: params)
            return wrapResult(responseBody, id: request["id"])

        default:
            throw A2ATransportError.unsupportedOperation(
                message: "REST transport does not support method '\(method)'"
            )
        }
    }

    // MARK: - A2ATransport: sendStream

    public func sendStream(
        _ request: [String: Any],
        params: ServiceParams
    ) -> AsyncThrowingStream<[String: Any], Error> {
        guard let method = request["method"] as? String else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: A2ATransportError.parsing(
                    message: "REST transport: missing 'method' in request"
                ))
            }
        }

        let rpcParams = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "message/stream":
            return sseStream(
                path: "/messages:stream",
                body: rpcParams,
                extraParams: params,
                requestId: request["id"]
            )

        case "tasks/subscribe":
            guard let id = rpcParams["id"] as? String, !id.isEmpty else {
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: A2ATransportError.parsing(
                        message: "REST transport: 'tasks/subscribe' requires 'id' param"
                    ))
                }
            }
            return sseStream(
                path: "/tasks/\(id):subscribe",
                body: rpcParams,
                extraParams: params,
                requestId: request["id"]
            )

        default:
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: A2ATransportError.unsupportedOperation(
                    message: "REST transport does not support streaming for method '\(method)'"
                ))
            }
        }
    }

    public func close() {}

    // MARK: - HTTP primitives

    private func executeGet(url: URL, extraParams: ServiceParams) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(&request, extraParams: extraParams)

        #if canImport(os)
        logger.debug("REST GET \(url)")
        #endif

        let (data, response) = try await perform(request)
        try checkStatus(response, data: data)
        return try parseJSON(data)
    }

    private func executePost(
        url: URL,
        body: [String: Any],
        extraParams: ServiceParams
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(&request, extraParams: extraParams, contentType: "application/json")
        request.httpBody = try encodeJSON(body)

        #if canImport(os)
        logger.debug("REST POST \(url)")
        #endif

        let (data, response) = try await perform(request)
        try checkStatus(response, data: data)
        return try parseJSON(data)
    }

    private func executeDelete(url: URL, extraParams: ServiceParams) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyHeaders(&request, extraParams: extraParams)

        #if canImport(os)
        logger.debug("REST DELETE \(url)")
        #endif

        let (data, response) = try await perform(request)
        try checkStatus(response, data: data)
        // DELETE may return empty body — treat as empty object.
        if data.isEmpty { return [:] }
        return try parseJSON(data)
    }

    // MARK: - SSE streaming

    private func sseStream(
        path: String,
        body: [String: Any],
        extraParams: ServiceParams,
        requestId: Any?
    ) -> AsyncThrowingStream<[String: Any], Error> {
        let (stream, continuation) = AsyncThrowingStream<[String: Any], Error>.makeStream()

        let capturedURL = url
        let capturedAuthParams = authParams
        let capturedSession = session
        let parser = SseParser()

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } catch {
            continuation.finish(throwing: A2ATransportError.parsing(
                message: "Failed to encode request body: \(error.localizedDescription)"
            ))
            return stream
        }

        // Merge headers eagerly before spawning the task.
        var baseParams = ServiceParams([
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        ])
        for (k, vals) in capturedAuthParams.asDictionary() {
            baseParams.append(k, vals)
        }
        var finalHeadersDict = baseParams.asHTTPHeaders()
        for (k, v) in extraParams.asHTTPHeaders() {
            finalHeadersDict[k] = v
        }
        let finalHeaders = finalHeadersDict

        let task = _Concurrency.Task {
            guard let restURL = URL(string: "\(capturedURL)\(path)") else {
                continuation.finish(throwing: A2ATransportError.network(
                    message: "Invalid URL: \(capturedURL)\(path)"
                ))
                return
            }

            var urlRequest = URLRequest(url: restURL)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = bodyData
            for (key, value) in finalHeaders {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }

            do {
                let (bytes, response) = try await capturedSession.bytes(for: urlRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.finish(throwing: A2ATransportError.network(
                        message: "Non-HTTP response received."
                    ))
                    return
                }
                if httpResponse.statusCode >= 400 {
                    continuation.finish(throwing: A2ATransportError.http(
                        statusCode: httpResponse.statusCode,
                        reason: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                    ))
                    return
                }

                let lineStream = bytes.lines
                let events = parser.parse(lineStream)
                for try await event in events {
                    // Wrap each SSE event in a JSON-RPC result envelope.
                    nonisolated(unsafe) let wrapped = RestTransport.wrapResult(event, id: requestId)
                    continuation.yield(wrapped)
                }
                continuation.finish()
            } catch {
                if let transportError = error as? A2ATransportError {
                    continuation.finish(throwing: transportError)
                } else {
                    continuation.finish(throwing: A2ATransportError.network(
                        message: "SSE stream error: \(error.localizedDescription)"
                    ))
                }
            }
        }

        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Helpers

    private func buildURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: "\(url)\(path)") else {
            throw A2ATransportError.network(message: "Invalid URL: \(url)\(path)")
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let built = components.url else {
            throw A2ATransportError.network(message: "Failed to build URL for path \(path)")
        }
        return built
    }

    private func applyHeaders(
        _ request: inout URLRequest,
        extraParams: ServiceParams,
        contentType: String? = nil
    ) {
        var merged = authParams.asHTTPHeaders()
        for (k, v) in extraParams.asHTTPHeaders() {
            merged[k] = v
        }
        if let ct = contentType {
            merged["Content-Type"] = ct
        }
        for (key, value) in merged {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw A2ATransportError.network(message: error.localizedDescription)
        }
    }

    private func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw A2ATransportError.network(message: "Non-HTTP response received.")
        }
        if http.statusCode >= 400 {
            throw A2ATransportError.http(
                statusCode: http.statusCode,
                reason: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any] else {
            throw A2ATransportError.parsing(message: "Response is not a JSON object.")
        }
        return dict
    }

    private func encodeJSON(_ body: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw A2ATransportError.parsing(
                message: "Failed to encode request body: \(error.localizedDescription)"
            )
        }
    }

    /// Wraps a REST response body in a JSON-RPC 2.0 `result` envelope.
    ///
    /// ``A2AClient`` always unwraps the `result` key before decoding, so every
    /// response—regardless of transport—must arrive in this shape.
    private static func wrapResult(_ body: [String: Any], id: Any?) -> [String: Any] {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "result": body,
        ]
        if let id = id {
            envelope["id"] = id
        }
        return envelope
    }

    /// Instance wrapper forwarding to the static helper (used in closures where
    /// `self` is unavailable or would cause capture issues).
    private func wrapResult(_ body: [String: Any], id: Any?) -> [String: Any] {
        RestTransport.wrapResult(body, id: id)
    }
}
