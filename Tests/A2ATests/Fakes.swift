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
@testable import A2AClient
import A2ACore
@testable import A2AServer

// MARK: - TestTransport

/// A configurable fake transport for unit tests.
///
/// Each method dispatches to a corresponding closure field (e.g. `sendFn`).
/// Tests set these fields to control what the transport returns, capturing
/// call arguments as a side-effect. Mirrors Go's `testTransport` struct from
/// `a2aclient/client_test.go`.
///
/// All captured state is protected by a lock so tests can read it from the
/// main actor without data races.
final class TestTransport: A2ATransport, @unchecked Sendable {

    // MARK: - Closure fields (set by each test)

    var getFn: ((String, ServiceParams) async throws -> [String: Any])?
    var sendFn: (([String: Any], String, ServiceParams) async throws -> [String: Any])?
    var sendStreamFn: (([String: Any], ServiceParams) -> AsyncThrowingStream<[String: Any], Error>)?

    // MARK: - Captured call arguments (readable by tests)

    private let _lock = NSLock()

    private var _sendRequests: [[String: Any]] = []
    private var _sendStreamRequests: [[String: Any]] = []
    private var _sentParams: [ServiceParams] = []

    /// All requests passed to `send(_:path:params:)` in call order.
    var sendRequests: [[String: Any]] { _lock.withLock { _sendRequests } }
    /// All requests passed to `sendStream(_:params:)` in call order.
    var sendStreamRequests: [[String: Any]] { _lock.withLock { _sendStreamRequests } }
    /// ServiceParams passed to each `send` call.
    var sentParams: [ServiceParams] { _lock.withLock { _sentParams } }

    // MARK: - A2ATransport

    var authParams: ServiceParams { ServiceParams() }

    func get(path: String, params: ServiceParams = ServiceParams()) async throws -> [String: Any] {
        guard let fn = getFn else {
            throw TestError.notImplemented("TestTransport.get not configured")
        }
        return try await fn(path, params)
    }

    func send(
        _ request: [String: Any],
        path: String = "",
        params: ServiceParams = ServiceParams()
    ) async throws -> [String: Any] {
        _lock.withLock {
            _sendRequests.append(request)
            _sentParams.append(params)
        }
        guard let fn = sendFn else {
            throw TestError.notImplemented("TestTransport.send not configured")
        }
        return try await fn(request, path, params)
    }

    func sendStream(
        _ request: [String: Any],
        params: ServiceParams = ServiceParams()
    ) -> AsyncThrowingStream<[String: Any], Error> {
        _lock.withLock { _sendStreamRequests.append(request) }
        guard let fn = sendStreamFn else {
            return AsyncThrowingStream { $0.finish(throwing: TestError.notImplemented("TestTransport.sendStream not configured")) }
        }
        return fn(request, params)
    }

    func close() {}
}

// MARK: - TestHandler

/// A configurable handler for unit tests.
///
/// Captures the last request and response seen by its hooks, and dispatches
/// to optional closure overrides. Mirrors Go's `testInterceptor` struct from
/// `a2aclient/client_test.go`.
final class TestHandler: A2AHandler, @unchecked Sendable {

    // MARK: - Captured values

    private let _lock = NSLock()
    private var _lastRequest: [String: Any]?
    private var _lastResponse: [String: Any]?

    /// The most recent request seen by `handleRequest(_:)`.
    var lastRequest: [String: Any]? { _lock.withLock { _lastRequest } }
    /// The most recent response seen by `handleResponse(_:)`.
    var lastResponse: [String: Any]? { _lock.withLock { _lastResponse } }

    // MARK: - Closure fields

    var handleRequestFn: (([String: Any]) async throws -> [String: Any])?
    var handleResponseFn: (([String: Any]) async throws -> [String: Any])?

    // MARK: - A2AHandler

    func handleRequest(_ request: [String: Any]) async throws -> [String: Any] {
        _lock.withLock { _lastRequest = request }
        if let fn = handleRequestFn {
            return try await fn(request)
        }
        return request
    }

    func handleResponse(_ response: [String: Any]) async throws -> [String: Any] {
        _lock.withLock { _lastResponse = response }
        if let fn = handleResponseFn {
            return try await fn(response)
        }
        return response
    }
}

// MARK: - TestError

enum TestError: Error, Equatable {
    case notImplemented(String)
    case custom(String)
}

// MARK: - Stream helpers

/// Collects all events from an AsyncThrowingStream into an array.
func drainStream<T>(_ stream: AsyncThrowingStream<T, Error>) async throws -> [T] {
    var result: [T] = []
    for try await event in stream {
        result.append(event)
    }
    return result
}

/// Creates an AsyncThrowingStream that emits the given dictionaries then finishes.
func makeStream(events: [[String: Any]]) -> AsyncThrowingStream<[String: Any], Error> {
    AsyncThrowingStream { continuation in
        for event in events {
            continuation.yield(event)
        }
        continuation.finish()
    }
}

/// Creates an AsyncThrowingStream that finishes with an error.
func makeErrorStream(error: Error) -> AsyncThrowingStream<[String: Any], Error> {
    AsyncThrowingStream { continuation in
        continuation.finish(throwing: error)
    }
}
