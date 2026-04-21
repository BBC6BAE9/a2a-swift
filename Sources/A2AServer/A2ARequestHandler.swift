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

// MARK: - A2AServerError

/// Errors thrown by the A2A server-side components.
public enum A2AServerError: Error, Sendable, Equatable {
    /// The request is missing required parameters.
    case invalidParams(message: String)
    /// The requested operation is not supported.
    case unsupportedOperation
    /// Push notifications are not configured on this server.
    case pushNotificationNotSupported
    /// The extended agent card is not configured.
    case extendedCardNotConfigured
    /// An internal server error.
    case internalError(message: String)
    /// The task was not found.
    case taskNotFound
    /// The task cannot be canceled in its current state.
    case taskNotCancelable

    /// The JSON-RPC error code corresponding to this error.
    public var jsonRPCCode: Int {
        switch self {
        case .invalidParams:               return -32_600
        case .unsupportedOperation:        return -32_004
        case .pushNotificationNotSupported: return -32_007
        case .extendedCardNotConfigured:   return -32_010
        case .internalError:               return -32_000
        case .taskNotFound:                return -32_001
        case .taskNotCancelable:           return -32_002
        }
    }
}

// MARK: - RequestHandler

/// Transport-agnostic interface for handling incoming A2A server requests.
///
/// ``DefaultRequestHandler`` provides the concrete implementation; the
/// ``A2AServer`` translates HTTP/JSON-RPC calls into calls on this protocol.
///
/// Mirrors Go's `a2asrv.RequestHandler` in `a2asrv/handler.go`.
public protocol RequestHandler: Sendable {
    /// Handle a `tasks/get` request.
    func getTask(_ request: GetTaskRequest) async throws -> Task
    /// Handle a `tasks/list` request.
    func listTasks(_ request: ListTasksRequest) async throws -> ListTasksResponse
    /// Handle a `tasks/cancel` request.
    func cancelTask(_ request: CancelTaskRequest) async throws -> Task
    /// Handle a `message/send` request (non-streaming).
    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse
    /// Handle a `message/stream` request (streaming).
    func sendStreamingMessage(_ request: SendMessageRequest) -> AsyncThrowingStream<AgentEvent, Error>
    /// Handle a `tasks/resubscribe` request (streaming).
    func subscribeToTask(_ request: SubscribeToTaskRequest) -> AsyncThrowingStream<AgentEvent, Error>
    /// Handle a `tasks/pushNotificationConfig/get` request.
    func getTaskPushConfig(_ request: GetTaskPushNotificationConfigRequest) async throws -> TaskPushNotificationConfig
    /// Handle a `tasks/pushNotificationConfig/list` request.
    func listTaskPushConfigs(_ request: ListTaskPushNotificationConfigsRequest) async throws -> [TaskPushNotificationConfig]
    /// Handle a `tasks/pushNotificationConfig/set` request.
    func createTaskPushConfig(_ config: TaskPushNotificationConfig) async throws -> TaskPushNotificationConfig
    /// Handle a `tasks/pushNotificationConfig/delete` request.
    func deleteTaskPushConfig(_ request: DeleteTaskPushNotificationConfigRequest) async throws
    /// Handle an `agent/authenticatedExtendedCard` request.
    func getExtendedAgentCard(_ request: GetExtendedAgentCardRequest) async throws -> AgentCard
}

// MARK: - A2ARequestHandlerOptions

/// Configuration for ``DefaultRequestHandler``.
public struct A2ARequestHandlerOptions: Sendable {
    /// Override the task store.  Defaults to ``InMemoryTaskStore`` when `nil`.
    public var taskStore: (any TaskStore)?
    /// Push config store.  When `nil`, push methods return
    /// ``A2AServerError/pushNotificationNotSupported``.
    public var pushConfigStore: (any PushConfigStore)?
    /// Push sender. When `nil`, push methods return
    /// ``A2AServerError/pushNotificationNotSupported``.
    public var pushSender: (any PushSender)?
    /// Agent capability flags used to gate optional features.
    public var capabilities: AgentCapabilities?
    /// Closure that returns the authenticated extended agent card.
    public var extendedCardProducer: (@Sendable () async throws -> AgentCard)?

    public init() {}
}

// MARK: - DefaultRequestHandler

/// The default ``RequestHandler`` implementation.
///
/// Wires together an ``AgentExecutor``, ``ExecutionManager``, ``TaskStore``,
/// and optional push-notification components.
///
/// Mirrors Go's `defaultRequestHandler` in `a2asrv/handler.go`.
///
/// ## Usage
///
/// ```swift
/// let handler = DefaultRequestHandler(executor: MyExecutor())
/// let server  = A2AServer(handler: handler, agentCard: myCard)
/// ```
public final class DefaultRequestHandler: RequestHandler, @unchecked Sendable {

    // MARK: - Properties

    private let execManager: ExecutionManager
    private let taskStore: any TaskStore
    private let pushConfigStore: (any PushConfigStore)?
    private let pushSender: (any PushSender)?
    private let capabilities: AgentCapabilities?
    private let extendedCardProducer: (@Sendable () async throws -> AgentCard)?

    // MARK: - Initialiser

    /// Creates a ``DefaultRequestHandler``.
    ///
    /// - Parameters:
    ///   - executor: The agent implementation.
    ///   - options: Optional configuration overrides.
    public init(executor: any AgentExecutor, options: A2ARequestHandlerOptions = A2ARequestHandlerOptions()) {
        let store: any TaskStore = options.taskStore ?? InMemoryTaskStore()
        self.taskStore = store
        self.pushConfigStore = options.pushConfigStore
        self.pushSender = options.pushSender
        self.capabilities = options.capabilities
        self.extendedCardProducer = options.extendedCardProducer
        self.execManager = ExecutionManager(
            executor: executor,
            store: store,
            pushConfigStore: options.pushConfigStore,
            pushSender: options.pushSender
        )
    }

    // MARK: - RequestHandler — task methods

    public func getTask(_ request: GetTaskRequest) async throws -> Task {
        guard !request.id.isEmpty else {
            throw A2AServerError.invalidParams(message: "task ID is required")
        }
        do {
            var stored = try await taskStore.get(taskID: request.id)
            // Apply history trimming if requested.
            if request.hasHistoryLength {
                let len = Int(request.historyLength)
                if len == 0 {
                    stored.task.history = []
                } else if len < stored.task.history.count {
                    stored.task.history = Array(stored.task.history.suffix(len))
                }
            }
            return stored.task
        } catch TaskStoreError.taskNotFound {
            throw A2AServerError.taskNotFound
        }
    }

    public func listTasks(_ request: ListTasksRequest) async throws -> ListTasksResponse {
        return try await taskStore.list(request)
    }

    public func cancelTask(_ request: CancelTaskRequest) async throws -> Task {
        guard !request.id.isEmpty else {
            throw A2AServerError.invalidParams(message: "task ID is required")
        }
        do {
            return try await execManager.cancel(request: request)
        } catch TaskStoreError.taskNotFound {
            throw A2AServerError.taskNotFound
        }
    }

    // MARK: - RequestHandler — message methods

    public func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        let stream = try await execManager.execute(request: request)
        var lastEvent: AgentEvent? = nil

        for try await event in stream {
            // ReturnImmediately: return after the first task event.
            if request.configuration.returnImmediately {
                if case .message(let m) = event {
                    var resp = SendMessageResponse()
                    resp.message = m
                    return resp
                }
                // For any task event, load and return the task.
                if let tid = event.taskID {
                    let stored = try await taskStore.get(taskID: tid)
                    var resp = SendMessageResponse()
                    resp.task = stored.task
                    return resp
                }
            }

            // Non-streaming clients must be notified when auth is required.
            if case .task(let t) = event, t.status.state == .authRequired {
                let stored = try await taskStore.get(taskID: t.id)
                var resp = SendMessageResponse()
                resp.task = stored.task
                return resp
            }
            if case .statusUpdate(let e) = event, e.status.state == .authRequired {
                let stored = try await taskStore.get(taskID: e.taskID)
                var resp = SendMessageResponse()
                resp.task = stored.task
                return resp
            }

            lastEvent = event
        }

        // Resolve final event.
        if let event = lastEvent {
            if case .message(let m) = event {
                var resp = SendMessageResponse()
                resp.message = m
                return resp
            }
            if let tid = event.taskID {
                let stored = try await taskStore.get(taskID: tid)
                var resp = SendMessageResponse()
                resp.task = stored.task
                return resp
            }
        }

        throw A2AServerError.internalError(message: "execution finished without producing any events")
    }

    public func sendStreamingMessage(_ request: SendMessageRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            _Concurrency.Task {
                do {
                    let stream = try await self.execManager.execute(request: request)
                    for try await event in stream {
                        continuation.yield(event)
                        if event.isFinal { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func subscribeToTask(_ request: SubscribeToTaskRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            _Concurrency.Task {
                do {
                    let stream = try await self.execManager.resubscribe(taskID: request.id)
                    for try await event in stream {
                        continuation.yield(event)
                        if event.isFinal { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - RequestHandler — push notification methods

    public func getTaskPushConfig(_ request: GetTaskPushNotificationConfigRequest) async throws -> TaskPushNotificationConfig {
        try requirePushSupport()
        guard let store = pushConfigStore else {
            throw A2AServerError.pushNotificationNotSupported
        }
        guard let config = try await store.get(taskID: request.taskID, configID: request.id) else {
            throw PushError.configNotFound
        }
        return config
    }

    public func listTaskPushConfigs(_ request: ListTaskPushNotificationConfigsRequest) async throws -> [TaskPushNotificationConfig] {
        try requirePushSupport()
        guard let store = pushConfigStore else {
            throw A2AServerError.pushNotificationNotSupported
        }
        return try await store.list(taskID: request.taskID)
    }

    public func createTaskPushConfig(_ config: TaskPushNotificationConfig) async throws -> TaskPushNotificationConfig {
        try requirePushSupport()
        guard let store = pushConfigStore else {
            throw A2AServerError.pushNotificationNotSupported
        }
        return try await store.save(taskID: config.taskID, config: config)
    }

    public func deleteTaskPushConfig(_ request: DeleteTaskPushNotificationConfigRequest) async throws {
        try requirePushSupport()
        guard let store = pushConfigStore else {
            throw A2AServerError.pushNotificationNotSupported
        }
        try await store.delete(taskID: request.taskID, configID: request.id)
    }

    // MARK: - RequestHandler — extended card

    public func getExtendedAgentCard(_ request: GetExtendedAgentCardRequest) async throws -> AgentCard {
        if let caps = capabilities, !caps.extendedAgentCard {
            throw A2AServerError.unsupportedOperation
        }
        guard let producer = extendedCardProducer else {
            throw A2AServerError.extendedCardNotConfigured
        }
        return try await producer()
    }

    // MARK: - Helpers

    private func requirePushSupport() throws {
        if let caps = capabilities, !caps.pushNotifications {
            throw A2AServerError.pushNotificationNotSupported
        }
        if capabilities != nil && (pushConfigStore == nil || pushSender == nil) {
            throw A2AServerError.internalError(message: "push notifications enabled but not configured")
        }
        if capabilities == nil && (pushConfigStore == nil || pushSender == nil) {
            throw A2AServerError.pushNotificationNotSupported
        }
    }
}
