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

// MARK: - ActiveExecution (internal)

/// Holds a live executor stream and a fan-out continuation so multiple
/// subscribers can observe the same execution.
final class ActiveExecution: @unchecked Sendable {
    let taskID: String
    // All registered continuations receive every event via broadcast.
    private var continuations: [UUID: AsyncThrowingStream<AgentEvent, Error>.Continuation] = [:]
    private let lock = NSLock()

    init(taskID: String) {
        self.taskID = taskID
    }

    /// Register a new subscriber and return a stream that will receive events.
    func subscribe() -> AsyncThrowingStream<AgentEvent, Error> {
        let id = UUID()
        let stream = AsyncThrowingStream<AgentEvent, Error> { cont in
            self.lock.withLock {
                self.continuations[id] = cont
            }
            cont.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.continuations.removeValue(forKey: id) }
            }
        }
        return stream
    }

    /// Yield an event to all registered subscribers.
    func yield(_ event: AgentEvent) {
        lock.withLock {
            for cont in continuations.values { cont.yield(event) }
        }
    }

    /// Finish all subscriber streams (cleanly or with error).
    func finish(throwing error: Error? = nil) {
        lock.withLock {
            for cont in continuations.values {
                if let error { cont.finish(throwing: error) }
                else { cont.finish() }
            }
        }
    }
}

// MARK: - ExecutionManagerError

/// Errors thrown by ``ExecutionManager``.
public enum ExecutionManagerError: Error, Sendable {
    /// An execution is already active for this task ID.
    case executionInProgress
    /// No active execution was found for the requested task ID.
    case noActiveExecution
}

// MARK: - ExecutionManager

/// Manages the lifecycle of agent executions: start, cancel, and resubscribe.
///
/// A single ``ExecutionManager`` per server instance ensures that only one
/// concurrent execution runs per task ID.  Multiple callers can subscribe to
/// the same execution and each receives all events via an internal fan-out.
///
/// Mirrors Go's `taskexec.LocalManager` in `internal/taskexec/local_manager.go`,
/// simplified to single-process operation.
public actor ExecutionManager {

    // MARK: - Dependencies

    private let store: any TaskStore
    private let updateManager: TaskUpdateManager
    private let executor: any AgentExecutor
    private let pushConfigStore: (any PushConfigStore)?
    private let pushSender: (any PushSender)?

    // MARK: - State

    /// In-flight executions keyed by task ID.
    private var active: [String: ActiveExecution] = [:]

    // MARK: - Initialiser

    /// Creates an ``ExecutionManager``.
    ///
    /// - Parameters:
    ///   - executor: The ``AgentExecutor`` that processes requests.
    ///   - store: Persistence for task state.
    ///   - pushConfigStore: Optional push config store; pass `nil` to disable push.
    ///   - pushSender: Optional push sender; pass `nil` to disable push.
    public init(
        executor: any AgentExecutor,
        store: any TaskStore,
        pushConfigStore: (any PushConfigStore)? = nil,
        pushSender: (any PushSender)? = nil
    ) {
        self.executor = executor
        self.store = store
        self.updateManager = TaskUpdateManager(store: store)
        self.pushConfigStore = pushConfigStore
        self.pushSender = pushSender
    }

    // MARK: - Public API

    /// Start (or reuse) an execution for the given message request.
    ///
    /// If no execution is in progress for `request.message.taskID`,
    /// creates a new task, transitions it to `.working`, and launches the
    /// executor in a background `Task`.
    ///
    /// - Returns: An ``AsyncThrowingStream`` that yields every ``AgentEvent``
    ///   produced by this execution.
    public func execute(request: SendMessageRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        // Validate request.
        guard request.hasMessage else {
            throw A2AServerError.invalidParams(message: "message is required")
        }
        let message = request.message
        guard !message.messageID.isEmpty else {
            throw A2AServerError.invalidParams(message: "message ID is required")
        }
        guard !message.parts.isEmpty else {
            throw A2AServerError.invalidParams(message: "message parts are required")
        }

        // Determine task ID: use existing from message, or generate new.
        let taskID = message.taskID.isEmpty ? UUID().uuidString : message.taskID
        let contextID = message.contextID.isEmpty ? UUID().uuidString : message.contextID

        // If there's already an active execution, subscribe to it.
        if let existing = active[taskID] {
            return existing.subscribe()
        }

        // Load or create the initial task.
        var storedTask: StoredTask? = nil
        if !message.taskID.isEmpty {
            storedTask = try? await store.get(taskID: taskID)
        }

        // Create initial task in store.
        var initialTask = Task()
        initialTask.id = taskID
        initialTask.contextID = contextID
        var initialStatus = TaskStatus()
        initialStatus.state = .submitted
        initialTask.status = initialStatus
        initialTask.history = [message]

        let initialVersion: TaskVersion
        if storedTask == nil {
            initialVersion = try await store.create(task: initialTask)
            storedTask = StoredTask(task: initialTask, version: initialVersion)
        } else {
            initialVersion = storedTask!.version
        }

        // Transition to working.
        var workingTask = initialTask
        var workingStatus = TaskStatus()
        workingStatus.state = .working
        workingTask.status = workingStatus

        var workingEvent = TaskStatusUpdateEvent()
        workingEvent.taskID = taskID
        workingEvent.status = workingStatus
        let workingStored = try await updateManager.process(
            event: .statusUpdate(workingEvent),
            existing: storedTask
        )

        // Build executor context.
        let execContext = ExecutorContext(
            message: message,
            taskID: taskID,
            storedTask: workingStored,
            contextID: contextID,
            serviceParams: ServiceParams(),
            tenant: request.tenant
        )

        // Create fan-out bucket.
        let execution = ActiveExecution(taskID: taskID)
        active[taskID] = execution

        // Launch background driver.
        let executorRef = executor
        let updateManagerRef = updateManager
        let pushConfigStoreRef = pushConfigStore
        let pushSenderRef = pushSender
        _ = store

        _Concurrency.Task.detached {
            var last: StoredTask? = workingStored
            let stream = executorRef.execute(context: execContext)
            do {
                for try await event in stream {
                    // Yield to all subscribers first.
                    execution.yield(event)

                    // Persist state change (ignoring message events).
                    if case .message = event { /* no store update */ } else {
                        last = try await updateManagerRef.process(event: event, existing: last)
                    }

                    // Send push notifications if configured.
                    if let configStore = pushConfigStoreRef,
                       let sender = pushSenderRef,
                       let tid = event.taskID {
                        let configs = (try? await configStore.list(taskID: tid)) ?? []
                        for cfg in configs {
                            try? await sender.sendPush(config: cfg, event: event)
                        }
                    }

                    // Stop driving if this is the final event.
                    if event.isFinal { break }
                }
                execution.finish()
            } catch {
                // Mark task as failed.
                if let tid = execContext.taskID.isEmpty ? nil : execContext.taskID {
                    try? await updateManagerRef.setFailed(taskID: tid, error: error)
                }
                execution.finish(throwing: error)
            }

            // Clean up.
            await self.removeExecution(taskID: taskID)
        }

        return execution.subscribe()
    }

    /// Re-attach to a running execution by task ID.
    ///
    /// - Throws: ``ExecutionManagerError/noActiveExecution`` if no execution
    ///   is in progress for `taskID`.
    public func resubscribe(taskID: String) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard let execution = active[taskID] else {
            throw ExecutionManagerError.noActiveExecution
        }
        return execution.subscribe()
    }

    /// Cancel the execution for `request.id`.
    ///
    /// Invokes ``AgentExecutor/cancel(context:)`` and waits for the canceler
    /// to emit a terminal event.
    ///
    /// - Returns: The task in its final canceled state.
    public func cancel(request: CancelTaskRequest) async throws -> Task {
        let taskID = request.id
        let storedTask = try await store.get(taskID: taskID)

        let cancelContext = ExecutorContext(
            message: Message(),
            taskID: taskID,
            storedTask: storedTask,
            contextID: storedTask.task.contextID,
            tenant: request.tenant
        )

        var last: StoredTask? = storedTask
        for try await event in executor.cancel(context: cancelContext) {
            if case .message = event { break }
            last = try await updateManager.process(event: event, existing: last)
            if event.isFinal { break }
        }

        return (try? await store.get(taskID: taskID).task) ?? storedTask.task
    }

    // MARK: - Private

    private func removeExecution(taskID: String) {
        active.removeValue(forKey: taskID)
    }
}
