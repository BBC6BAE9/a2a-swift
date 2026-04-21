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

// MARK: - InMemoryTaskStore

/// An actor-based, in-memory implementation of ``TaskStore``.
///
/// Suitable for development, testing, and single-process deployments.
/// All state is lost when the process exits.
///
/// ## Thread safety
///
/// Actor isolation guarantees exclusive access to the internal dictionary
/// without manual locking.
///
/// ## Filtering
///
/// ``list(_:)`` supports filtering by `contextID`, `status`, and simple
/// cursor-based pagination via `pageToken` / `pageSize`.
///
/// Mirrors Go's `taskstore.InMemory` in `a2asrv/taskstore/inmemory.go`.
public actor InMemoryTaskStore: TaskStore {

    // MARK: - Properties

    /// Optional predicate that gates read access.
    ///
    /// When non-nil, only tasks for which `authenticator(task, params)` returns
    /// `true` are visible via ``get(taskID:)`` and ``list(_:)``.
    public let authenticator: (@Sendable (Task, ServiceParams) -> Bool)?

    /// Ordered list of task IDs for stable pagination.
    private var taskOrder: [String] = []
    /// Primary storage: taskID → StoredTask.
    private var tasks: [String: StoredTask] = [:]
    /// Monotonically increasing version counter.
    private var nextVersion: TaskVersion = 1

    // MARK: - Initialiser

    /// Creates an ``InMemoryTaskStore``.
    ///
    /// - Parameter authenticator: Optional closure used to filter tasks by
    ///   caller identity.  Passes the task and the current ``ServiceParams``
    ///   for header-based auth checks.  When `nil` (the default), all tasks
    ///   are visible.
    public init(authenticator: (@Sendable (Task, ServiceParams) -> Bool)? = nil) {
        self.authenticator = authenticator
    }

    // MARK: - TaskStore

    public func create(task: Task) async throws -> TaskVersion {
        guard tasks[task.id] == nil else {
            throw TaskStoreError.taskAlreadyExists
        }
        let version = nextVersion
        nextVersion &+= 1
        tasks[task.id] = StoredTask(task: task, version: version)
        taskOrder.append(task.id)
        return version
    }

    public func update(_ request: TaskUpdateRequest) async throws -> TaskVersion {
        let taskID = request.task.id
        guard let existing = tasks[taskID] else {
            throw TaskStoreError.taskNotFound
        }
        guard existing.version == request.previousVersion else {
            throw TaskStoreError.concurrentModification
        }
        let version = nextVersion
        nextVersion &+= 1
        tasks[taskID] = StoredTask(task: request.task, version: version)
        return version
    }

    public func get(taskID: String) async throws -> StoredTask {
        guard let stored = tasks[taskID] else {
            throw TaskStoreError.taskNotFound
        }
        return stored
    }

    public func list(_ request: ListTasksRequest) async throws -> ListTasksResponse {
        // Decode cursor: simple integer index into taskOrder.
        var startIndex = 0
        if !request.pageToken.isEmpty, let idx = Int(request.pageToken) {
            startIndex = idx
        }

        let pageSize = request.pageSize > 0 ? Int(request.pageSize) : Int.max

        // Collect filtered tasks.
        var results: [Task] = []
        var scanned = 0

        for id in taskOrder {
            guard let stored = tasks[id] else { continue }
            scanned += 1
            guard scanned > startIndex else { continue }

            let task = stored.task

            // Filter by contextID.
            if !request.contextID.isEmpty && task.contextID != request.contextID {
                continue
            }

            // Filter by status.
            if request.status != .unspecified && task.status.state != request.status {
                continue
            }

            results.append(task)
            if results.count >= pageSize { break }
        }

        // Build next-page token.
        var nextPageToken = ""
        let consumed = startIndex + results.count
        if consumed < taskOrder.count {
            nextPageToken = String(consumed)
        }

        var response = ListTasksResponse()
        response.tasks = results
        response.nextPageToken = nextPageToken
        return response
    }

    // MARK: - Testing helpers

    /// Returns the total number of tasks currently stored.
    public var count: Int { tasks.count }

    /// Removes all tasks (for test teardown).
    public func removeAll() {
        tasks.removeAll()
        taskOrder.removeAll()
        nextVersion = 1
    }
}
