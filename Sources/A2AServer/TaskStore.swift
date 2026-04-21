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

// MARK: - TaskVersion

/// An integer version token used for optimistic concurrency control.
///
/// Every ``StoredTask`` carries a version that is incremented on each
/// successful ``TaskStore/update(_:)`` call.  Callers must supply the version
/// they last read; if the store has advanced past that version the update is
/// rejected with ``TaskStoreError/concurrentModification``.
///
/// Mirrors Go's `taskstore.TaskVersion` in `a2asrv/taskstore/api.go`.
public typealias TaskVersion = Int64

/// Sentinel value indicating no version has been assigned yet.
///
/// Pass this as `previousVersion` in a ``TaskUpdateRequest`` when you have
/// never read the task from the store (e.g. creating an initial task and
/// immediately updating it).
public let taskVersionMissing: TaskVersion = 0

// MARK: - StoredTask

/// A task together with its concurrency version.
///
/// Returned by ``TaskStore/get(taskID:)`` and ``TaskStore/create(task:)``.
public struct StoredTask: Sendable {
    /// The current task value.
    public var task: Task
    /// The current version.  Increment when calling ``TaskStore/update(_:)``.
    public var version: TaskVersion

    /// Creates a ``StoredTask``.
    public init(task: Task, version: TaskVersion) {
        self.task = task
        self.version = version
    }
}

// MARK: - TaskUpdateRequest

/// Parameters for ``TaskStore/update(_:)``.
public struct TaskUpdateRequest: Sendable {
    /// The new task value to persist.
    public var task: Task
    /// The event that triggered this update (used for audit / push notification).
    public var event: AgentEvent
    /// The version the caller last observed.  Must match the stored version.
    public var previousVersion: TaskVersion

    /// Creates a ``TaskUpdateRequest``.
    public init(task: Task, event: AgentEvent, previousVersion: TaskVersion) {
        self.task = task
        self.event = event
        self.previousVersion = previousVersion
    }
}

// MARK: - TaskStoreError

/// Errors thrown by ``TaskStore`` operations.
public enum TaskStoreError: Error, Sendable, Equatable {
    /// A task with the same ID already exists.
    case taskAlreadyExists
    /// The stored version did not match `previousVersion` in the update request.
    case concurrentModification
    /// No task was found for the requested ID.
    case taskNotFound
}

// MARK: - TaskStore

/// A persistence layer for A2A tasks.
///
/// Implementations **must** be safe for concurrent use from multiple Swift
/// concurrency tasks.  The recommended approach is to use an `actor`, as done
/// by ``InMemoryTaskStore``.
///
/// Mirrors Go's `taskstore.Store` interface in `a2asrv/taskstore/api.go`.
public protocol TaskStore: Sendable {
    /// Persist a new task and return its initial version (`1`).
    ///
    /// - Throws: ``TaskStoreError/taskAlreadyExists`` if a task with the same
    ///   `task.id` is already stored.
    func create(task: Task) async throws -> TaskVersion

    /// Apply an update to an existing task.
    ///
    /// - Throws: ``TaskStoreError/concurrentModification`` if `request.previousVersion`
    ///   does not match the stored version.
    /// - Throws: ``TaskStoreError/taskNotFound`` if no task has `request.task.id`.
    /// - Returns: The new version number after a successful update.
    func update(_ request: TaskUpdateRequest) async throws -> TaskVersion

    /// Load a task by its ID.
    ///
    /// - Throws: ``TaskStoreError/taskNotFound`` when the ID is unknown.
    func get(taskID: String) async throws -> StoredTask

    /// List tasks matching the filters in `request`.
    func list(_ request: ListTasksRequest) async throws -> ListTasksResponse
}
