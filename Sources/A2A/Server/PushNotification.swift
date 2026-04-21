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

// MARK: - PushError

/// Errors produced by push-notification operations.
public enum PushError: Error, Sendable, Equatable {
    /// No push-notification configuration was found for the given IDs.
    case configNotFound
    /// The HTTP delivery attempt failed.
    case sendFailed(message: String)
}

// MARK: - PushConfigStore

/// Stores and retrieves ``TaskPushNotificationConfig`` records keyed by task ID.
///
/// Mirrors Go's `push.ConfigStore` in `a2asrv/push/api.go`.
public protocol PushConfigStore: Sendable {
    /// Persist a new or updated push configuration for `taskID`.
    ///
    /// Assigns a UUID `id` if the supplied config's `id` is empty.
    /// - Returns: The saved configuration (with `id` filled in).
    func save(taskID: String, config: TaskPushNotificationConfig) async throws -> TaskPushNotificationConfig

    /// Retrieve a specific config by `taskID` and `configID`.
    ///
    /// - Returns: The config, or `nil` if not found.
    func get(taskID: String, configID: String) async throws -> TaskPushNotificationConfig?

    /// List all configurations for `taskID`.
    func list(taskID: String) async throws -> [TaskPushNotificationConfig]

    /// Delete a specific config.
    func delete(taskID: String, configID: String) async throws

    /// Delete all configurations associated with `taskID`.
    func deleteAll(taskID: String) async throws
}

// MARK: - PushSender

/// Delivers push notifications to a remote endpoint.
///
/// Mirrors Go's `push.Sender` in `a2asrv/push/api.go`.
public protocol PushSender: Sendable {
    /// Send `event` to the endpoint described by `config`.
    func sendPush(config: TaskPushNotificationConfig, event: AgentEvent) async throws
}

// MARK: - InMemoryPushConfigStore

/// An actor-based in-memory implementation of ``PushConfigStore``.
///
/// Suitable for development and testing.  State is not persisted.
public actor InMemoryPushConfigStore: PushConfigStore {

    // MARK: - Storage

    /// `[taskID: [configID: config]]`
    private var store: [String: [String: TaskPushNotificationConfig]] = [:]

    // MARK: - Initialiser

    public init() {}

    // MARK: - PushConfigStore

    public func save(taskID: String, config: TaskPushNotificationConfig) async throws -> TaskPushNotificationConfig {
        var saved = config
        if saved.id.isEmpty { saved.id = UUID().uuidString }
        saved.taskID = taskID

        if store[taskID] == nil { store[taskID] = [:] }
        store[taskID]![saved.id] = saved
        return saved
    }

    public func get(taskID: String, configID: String) async throws -> TaskPushNotificationConfig? {
        return store[taskID]?[configID]
    }

    public func list(taskID: String) async throws -> [TaskPushNotificationConfig] {
        return Array(store[taskID]?.values ?? [:].values)
    }

    public func delete(taskID: String, configID: String) async throws {
        store[taskID]?.removeValue(forKey: configID)
    }

    public func deleteAll(taskID: String) async throws {
        store.removeValue(forKey: taskID)
    }

    // MARK: - Testing helpers

    /// Returns the total number of configs across all tasks.
    public var totalCount: Int {
        store.values.reduce(0) { $0 + $1.count }
    }
}

// MARK: - HTTPPushSender

/// Sends push notifications via HTTP POST.
///
/// Each notification is serialised as a ``StreamResponse`` JSON object and
/// posted to `config.url` with an optional Bearer or custom token.
///
/// Mirrors Go's `push.HTTPPushSender` in `a2asrv/push/sender.go`.
public struct HTTPPushSender: PushSender, Sendable {

    // MARK: - Configuration

    /// The URLSession used for outgoing HTTP requests.
    public let session: URLSession
    /// Timeout for each push delivery (default 30 s).
    public let timeout: TimeInterval
    /// When `true`, a failed delivery causes the `sendPush` call to throw.
    /// When `false` (default), delivery errors are silently swallowed.
    public let failOnError: Bool

    // MARK: - Initialiser

    /// Creates an ``HTTPPushSender``.
    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = 30,
        failOnError: Bool = false
    ) {
        self.session = session
        self.timeout = timeout
        self.failOnError = failOnError
    }

    // MARK: - PushSender

    public func sendPush(config: TaskPushNotificationConfig, event: AgentEvent) async throws {
        guard let url = URL(string: config.url), !config.url.isEmpty else { return }

        // Serialise event to StreamResponse JSON.
        let body: Data
        do {
            let response = streamResponse(for: event)
            body = try encodeToJSON(response)
        } catch {
            if failOnError { throw PushError.sendFailed(message: error.localizedDescription) }
            return
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Attach token header.
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode) else {
                let msg = "HTTP \(statusCode) from push endpoint \(config.url)"
                if failOnError { throw PushError.sendFailed(message: msg) }
                return
            }
        } catch let e as PushError {
            throw e
        } catch {
            if failOnError { throw PushError.sendFailed(message: error.localizedDescription) }
        }
    }

    // MARK: - Helpers

    private func streamResponse(for event: AgentEvent) -> StreamResponse {
        var r = StreamResponse()
        switch event {
        case .task(let t):          r.task = t
        case .message(let m):       r.message = m
        case .statusUpdate(let e):  r.statusUpdate = e
        case .artifactUpdate(let e): r.artifactUpdate = e
        }
        return r
    }
}

extension HTTPPushSender {
    /// Serialises a `SwiftProtobuf.Message` to JSON `Data`.
    func encodeToJSON<T: SwiftProtobuf.Message>(_ value: T) throws -> Data {
        let jsonString = try value.jsonString()
        guard let data = jsonString.data(using: .utf8) else {
            throw PushError.sendFailed(message: "Failed to encode event to UTF-8")
        }
        return data
    }
}
