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

// MARK: - AgentEvent

/// A discriminated union of all event types an ``AgentExecutor`` can yield.
///
/// Mirrors Go's `a2a.Event` interface, which is satisfied by `*a2a.Task`,
/// `*a2a.Message`, `*a2a.TaskStatusUpdateEvent`, and `*a2a.TaskArtifactUpdateEvent`.
public enum AgentEvent: Sendable {
    /// A full task snapshot (typically the initial submitted/working state).
    case task(Task)
    /// A direct message reply from the agent (terminal — no associated task).
    case message(Message)
    /// An incremental status update for a running task.
    case statusUpdate(TaskStatusUpdateEvent)
    /// An incremental artifact update for a running task.
    case artifactUpdate(TaskArtifactUpdateEvent)
}

// MARK: AgentEvent — helpers

extension AgentEvent {
    /// Returns `true` when this event signals the end of an execution.
    ///
    /// An execution is considered final when:
    /// - The event is a ``AgentEvent/message(_:)`` (agent replied directly).
    /// - The event is a ``AgentEvent/task(_:)`` or ``AgentEvent/statusUpdate(_:)``
    ///   whose state is terminal or interrupted (completed, failed, canceled,
    ///   rejected, inputRequired, authRequired).
    ///
    /// Mirrors Go's `taskupdate.IsFinal`.
    public var isFinal: Bool {
        switch self {
        case .message:
            return true
        case .task(let t):
            return t.status.state.isFinalOrInterrupted
        case .statusUpdate(let e):
            return e.status.state.isFinalOrInterrupted
        case .artifactUpdate:
            return false
        }
    }

    /// Extracts the task ID from any event variant, if present.
    public var taskID: String? {
        switch self {
        case .task(let t):       return t.id.isEmpty ? nil : t.id
        case .message(let m):    return m.taskID.isEmpty ? nil : m.taskID
        case .statusUpdate(let e): return e.taskID.isEmpty ? nil : e.taskID
        case .artifactUpdate(let e): return e.taskID.isEmpty ? nil : e.taskID
        }
    }
}

// MARK: - TaskState helpers

extension TaskState {
    /// Returns `true` for states that terminate or interrupt task execution.
    public var isFinalOrInterrupted: Bool {
        switch self {
        case .completed, .failed, .canceled, .rejected, .inputRequired, .authRequired:
            return true
        default:
            return false
        }
    }

    /// Returns `true` for states that permanently terminate task execution.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .canceled, .rejected:
            return true
        default:
            return false
        }
    }
}

// MARK: - ExecutorContext

/// Carries request-scoped data into an ``AgentExecutor``.
///
/// Mirrors Go's `a2asrv.ExecutorContext` in `a2asrv/exectx.go`.
public struct ExecutorContext: Sendable {
    /// The incoming message that triggered this execution.
    public var message: Message

    /// The ID of the task being processed.
    ///
    /// For new tasks this is a freshly generated UUID; for resumptions it is
    /// the ID of the existing task.
    public var taskID: String

    /// The previously stored task, or `nil` when this is a brand-new task.
    public var storedTask: StoredTask?

    /// The A2A context ID associated with this conversation thread.
    public var contextID: String

    /// Arbitrary key-value metadata from the request.
    ///
    /// Uses `[String: Any]` to match the protobuf `google.protobuf.Struct` type.
    public var metadata: [String: Any]

    /// Additional service parameters (e.g. authorization headers) forwarded
    /// from the transport layer.
    public var serviceParams: ServiceParams

    /// The tenant identifier, or empty string when not multi-tenant.
    public var tenant: String

    /// Creates an ``ExecutorContext``.
    public init(
        message: Message,
        taskID: String,
        storedTask: StoredTask? = nil,
        contextID: String,
        metadata: [String: Any] = [:],
        serviceParams: ServiceParams = ServiceParams(),
        tenant: String = ""
    ) {
        self.message = message
        self.taskID = taskID
        self.storedTask = storedTask
        self.contextID = contextID
        self.metadata = metadata
        self.serviceParams = serviceParams
        self.tenant = tenant
    }
}

// MARK: - AgentExecutor

/// The server-side protocol that every A2A agent implementation must conform to.
///
/// An executor receives an ``ExecutorContext`` describing the current request
/// and yields ``AgentEvent`` values until a final event is emitted.
///
/// Mirrors Go's `a2asrv.AgentExecutor` interface in `a2asrv/agentexec.go`.
///
/// ## Implementation contract
///
/// - `execute(context:)` **must** eventually yield a final event (see
///   ``AgentEvent/isFinal``).  The framework will not close the stream
///   artificially.
/// - `cancel(context:)` should yield a ``TaskStatusUpdateEvent`` with state
///   `.canceled` and then finish.
///
/// ## Example
///
/// ```swift
/// struct EchoExecutor: AgentExecutor {
///     func execute(context: ExecutorContext) -> AsyncThrowingStream<AgentEvent, Error> {
///         AsyncThrowingStream { cont in
///             var reply = Message()
///             reply.messageID = UUID().uuidString
///             reply.role = .agent
///             var part = Part(); part.text = "Echo: \(context.message.parts.first?.text ?? "")"
///             reply.parts = [part]
///             cont.yield(.message(reply))
///             cont.finish()
///         }
///     }
///     func cancel(context: ExecutorContext) -> AsyncThrowingStream<AgentEvent, Error> {
///         AsyncThrowingStream { cont in
///             var status = TaskStatus(); status.state = .canceled
///             var event = TaskStatusUpdateEvent()
///             event.taskID = context.taskID; event.status = status
///             cont.yield(.statusUpdate(event))
///             cont.finish()
///         }
///     }
/// }
/// ```
public protocol AgentExecutor: Sendable {
    /// Execute the request described by `context`.
    ///
    /// Yield ``AgentEvent`` values until a final event signals completion.
    func execute(context: ExecutorContext) -> AsyncThrowingStream<AgentEvent, Error>

    /// Cancel a running execution described by `context`.
    ///
    /// Should yield a terminal event with `.canceled` state.
    func cancel(context: ExecutorContext) -> AsyncThrowingStream<AgentEvent, Error>
}
