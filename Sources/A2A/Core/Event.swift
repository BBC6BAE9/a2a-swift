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

// MARK: - A2AEvent

/// Represents a single event received from the agent, typically during a stream.
///
/// This is a discriminated union based on the `kind` field. It maps to the
/// proto3 `StreamResponse` oneof (and reuses the `SendMessageResponse` oneof
/// for non-streaming responses that emit `.task` or `.message`).
///
/// Payload kinds:
/// - `"task"` — a full task snapshot (``A2ATask``)
/// - `"message"` — a standalone message from the agent (``A2AMessage``)
/// - `"task-status-update"` — a partial status update for an ongoing task
/// - `"artifact-update"` — a new or appended artifact for a task
///
/// Named `A2AEvent` to avoid conflict with SwiftUI/AppKit `Event` types.
///
/// Matches the proto3 `StreamResponse` / `SendMessageResponse` oneofs in
/// `specification/a2a.proto`.
public enum A2AEvent: Codable, Sendable, Equatable {

    /// A full task snapshot sent by the agent.
    case task(A2ATask)

    /// A standalone message from the agent (no associated task).
    case message(A2AMessage)

    /// An update to the task's status in a streaming context.
    case taskStatusUpdate(
        taskId: String,
        contextId: String,
        status: TaskStatus,
        isFinal: Bool
    )

    /// A new or updated artifact related to the task.
    case artifactUpdate(
        taskId: String,
        contextId: String,
        artifact: Artifact,
        append: Bool,
        lastChunk: Bool
    )

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case kind
        case taskId
        case contextId
        case status
        case isFinal = "final"
        case artifact
        case append
        case lastChunk
    }

    // MARK: - Decodable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)

        switch kind {
        case "task":
            self = .task(try A2ATask(from: decoder))

        case "message":
            self = .message(try A2AMessage(from: decoder))

        case "task-status-update":
            let taskId = try container.decode(String.self, forKey: .taskId)
            let contextId = try container.decode(String.self, forKey: .contextId)
            let status = try container.decode(TaskStatus.self, forKey: .status)
            let isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
            self = .taskStatusUpdate(taskId: taskId, contextId: contextId, status: status, isFinal: isFinal)

        case "artifact-update":
            let taskId = try container.decode(String.self, forKey: .taskId)
            let contextId = try container.decode(String.self, forKey: .contextId)
            let artifact = try container.decode(Artifact.self, forKey: .artifact)
            let append = try container.decodeIfPresent(Bool.self, forKey: .append) ?? false
            let lastChunk = try container.decodeIfPresent(Bool.self, forKey: .lastChunk) ?? false
            self = .artifactUpdate(taskId: taskId, contextId: contextId, artifact: artifact, append: append, lastChunk: lastChunk)

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown A2AEvent kind: \(kind)"
            )
        }
    }

    // MARK: - Encodable

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .task(let taskObj):
            try container.encode("task", forKey: .kind)
            try taskObj.encode(to: encoder)

        case .message(let msg):
            try container.encode("message", forKey: .kind)
            try msg.encode(to: encoder)

        case .taskStatusUpdate(let taskId, let contextId, let status, let isFinal):
            try container.encode("task-status-update", forKey: .kind)
            try container.encode(taskId, forKey: .taskId)
            try container.encode(contextId, forKey: .contextId)
            try container.encode(status, forKey: .status)
            try container.encode(isFinal, forKey: .isFinal)

        case .artifactUpdate(let taskId, let contextId, let artifact, let append, let lastChunk):
            try container.encode("artifact-update", forKey: .kind)
            try container.encode(taskId, forKey: .taskId)
            try container.encode(contextId, forKey: .contextId)
            try container.encode(artifact, forKey: .artifact)
            try container.encode(append, forKey: .append)
            try container.encode(lastChunk, forKey: .lastChunk)
        }
    }
}
