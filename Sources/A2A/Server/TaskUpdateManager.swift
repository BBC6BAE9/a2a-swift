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

// MARK: - TaskUpdateManager

/// Applies ``AgentEvent`` values to an existing task and persists the result
/// using the provided ``TaskStore``.
///
/// The manager handles:
/// - **Pure event application** — translates each event variant into the
///   appropriate mutation of a ``Task`` (status update, artifact merge, etc.).
/// - **Optimistic concurrency** — retries up to ``maxRetries`` times when the
///   store returns ``TaskStoreError/concurrentModification``.
/// - **Error recovery** — ``setFailed(taskID:error:)`` moves a task to the
///   `.failed` terminal state when an executor throws.
///
/// Mirrors Go's `taskupdate.Manager` in `internal/taskupdate/manager.go`.
public struct TaskUpdateManager: Sendable {

    // MARK: - Configuration

    /// Number of OCC retry attempts before propagating the error.
    public let maxRetries: Int

    /// The backing store.
    let store: any TaskStore

    // MARK: - Initialiser

    /// Creates a ``TaskUpdateManager``.
    ///
    /// - Parameters:
    ///   - store: The ``TaskStore`` to read from and write to.
    ///   - maxRetries: Maximum OCC retry count (default: 3).
    public init(store: any TaskStore, maxRetries: Int = 3) {
        self.store = store
        self.maxRetries = maxRetries
    }

    // MARK: - Public API

    /// Apply `event` to the task identified within it and persist the result.
    ///
    /// If `existing` is `nil` the task is loaded from the store first.
    /// On ``TaskStoreError/concurrentModification`` the manager reloads the
    /// stored task and retries up to ``maxRetries`` times.
    ///
    /// - Parameters:
    ///   - event: The event to process.
    ///   - existing: The last-known stored task, or `nil` to load from store.
    /// - Returns: The new ``StoredTask`` after a successful write.
    @discardableResult
    public func process(event: AgentEvent, existing: StoredTask?) async throws -> StoredTask {
        // Message events don't mutate task state — skip persistence.
        if case .message = event { return existing ?? StoredTask(task: Task(), version: taskVersionMissing) }

        guard let taskID = event.taskID, !taskID.isEmpty else {
            throw TaskUpdateError.missingTaskID
        }

        var current = existing
        var lastError: Error = TaskUpdateError.maxRetriesExceeded

        for _ in 0..<max(1, maxRetries) {
            // Load from store if needed.
            if current == nil {
                current = try await store.get(taskID: taskID)
            }
            guard let stored = current else {
                throw TaskStoreError.taskNotFound
            }

            // Apply the event to produce a new task value.
            let updated = applyEvent(event, to: stored.task)

            let req = TaskUpdateRequest(task: updated, event: event, previousVersion: stored.version)
            do {
                let newVersion = try await store.update(req)
                return StoredTask(task: updated, version: newVersion)
            } catch TaskStoreError.concurrentModification {
                // Reload on next iteration.
                current = nil
                lastError = TaskStoreError.concurrentModification
            }
        }
        throw lastError
    }

    /// Transition the task identified by `taskID` to the `.failed` state.
    ///
    /// Called by ``ExecutionManager`` when the executor throws unexpectedly.
    public func setFailed(taskID: String, error: Error) async throws {
        var current: StoredTask? = nil
        var lastError: Error = TaskUpdateError.maxRetriesExceeded

        for _ in 0..<max(1, maxRetries) {
            if current == nil {
                current = try await store.get(taskID: taskID)
            }
            guard let stored = current else { throw TaskStoreError.taskNotFound }

            var status = TaskStatus()
            status.state = .failed
            var failMsg = Message()
            failMsg.messageID = UUID().uuidString
            failMsg.role = .agent
            var part = Part()
            part.text = error.localizedDescription
            failMsg.parts = [part]
            status.message = failMsg

            var updated = stored.task
            updated.status = status

            // Build a synthetic status-update event for the update record.
            var statusEvent = TaskStatusUpdateEvent()
            statusEvent.taskID = taskID
            statusEvent.status = status
            let syntheticEvent = AgentEvent.statusUpdate(statusEvent)

            let req = TaskUpdateRequest(task: updated, event: syntheticEvent, previousVersion: stored.version)
            do {
                try await store.update(req)
                return
            } catch TaskStoreError.concurrentModification {
                current = nil
                lastError = TaskStoreError.concurrentModification
            }
        }
        throw lastError
    }

    // MARK: - Pure event application

    /// Returns a new `Task` that reflects the mutation implied by `event`.
    ///
    /// - `.task(t)` — replaces the task entirely.
    /// - `.statusUpdate(e)` — updates status, appends message to history.
    /// - `.artifactUpdate(e)` — appends or replaces an artifact.
    /// - `.message(m)` — no task mutation (caller handles the message directly).
    func applyEvent(_ event: AgentEvent, to task: Task) -> Task {
        var updated = task

        switch event {
        case .task(let t):
            // Full task snapshot from executor — merge status and metadata.
            updated.status = t.status
            if !t.artifacts.isEmpty { updated.artifacts = t.artifacts }

        case .statusUpdate(let e):
            updated.status = e.status
            // Append the status message to history if present.
            if e.status.hasMessage {
                updated.history.append(e.status.message)
            }

        case .artifactUpdate(let e):
            let artifact = e.artifact
            if e.append {
                // Find existing artifact by ID and append parts.
                if let idx = updated.artifacts.firstIndex(where: { $0.artifactID == artifact.artifactID }) {
                    updated.artifacts[idx].parts.append(contentsOf: artifact.parts)
                } else {
                    updated.artifacts.append(artifact)
                }
            } else {
                // Replace or insert.
                if let idx = updated.artifacts.firstIndex(where: { $0.artifactID == artifact.artifactID }) {
                    updated.artifacts[idx] = artifact
                } else {
                    updated.artifacts.append(artifact)
                }
            }

        case .message:
            break   // No task mutation for message events.
        }

        return updated
    }
}

// MARK: - TaskUpdateError

/// Errors produced by ``TaskUpdateManager``.
public enum TaskUpdateError: Error, Sendable {
    /// The event did not carry a task ID.
    case missingTaskID
    /// All OCC retry attempts were exhausted.
    case maxRetriesExceeded
}
