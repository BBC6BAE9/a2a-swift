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

// MARK: - V0 Wire Types
//
// Codable structs mirroring the A2A v0.3 JSON wire format.
// These are only used internally by ``V0JSONRPCTransport`` and
// ``V0AgentCardParser`` to serialise/deserialise v0.3 payloads.
//
// Mirrors the Go types in `a2acompat/a2av0/conversions.go`.

// MARK: - Enums

/// v0.3 task lifecycle state (raw string on the wire).
enum V0TaskState: String, Codable, Sendable {
    case submitted
    case working
    case inputRequired = "input-required"
    case completed
    case canceled
    case failed
    case rejected
    case authRequired = "auth-required"
    case unknown
}

/// v0.3 message sender role (raw string on the wire).
enum V0Role: String, Codable, Sendable {
    case user
    case agent
}

// MARK: - Part types

/// v0.3 TextPart  — `{"type":"text","text":"..."}`
struct V0TextPart: Codable, Sendable {
    var type: String = "text"
    var text: String
    var metadata: [String: AnyCodable]?
}

/// v0.3 DataPart  — `{"type":"data","data":{...}}`
struct V0DataPart: Codable, Sendable {
    var type: String = "data"
    var data: AnyCodable
    var metadata: [String: AnyCodable]?
}

/// v0.3 file content as raw bytes  — `{"bytes":"<base64>","mimeType":"...","name":"..."}`
struct V0FileBytes: Codable, Sendable {
    var bytes: String          // base64
    var mimeType: String?
    var name: String?
}

/// v0.3 file content as URI  — `{"uri":"...","mimeType":"...","name":"..."}`
struct V0FileURI: Codable, Sendable {
    var uri: String
    var mimeType: String?
    var name: String?
}

/// v0.3 FilePart  — `{"type":"file","file":{…}}`
///
/// The `file` field is either a ``V0FileBytes`` or ``V0FileURI``; we keep
/// both optional and pick whichever is non-nil at deserialisation.
struct V0FilePart: Codable, Sendable {
    var type: String = "file"
    var file: V0FileContent
    var metadata: [String: AnyCodable]?

    struct V0FileContent: Codable, Sendable {
        var bytes: String?
        var uri: String?
        var mimeType: String?
        var name: String?
    }
}

/// Discriminated union of the three v0.3 part kinds.
///
/// Decoded by inspecting the `"type"` field of the raw JSON object.
enum V0Part: Sendable {
    case text(V0TextPart)
    case data(V0DataPart)
    case file(V0FilePart)
}

extension V0Part: Codable {
    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let type_ = try container.decode(String.self, forKey: .type)
        switch type_ {
        case "text":
            self = .text(try V0TextPart(from: decoder))
        case "data":
            self = .data(try V0DataPart(from: decoder))
        case "file":
            self = .file(try V0FilePart(from: decoder))
        default:
            // Unknown part type: treat as text with empty string.
            var tp = V0TextPart(text: "")
            tp.type = type_
            self = .text(tp)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let p):  try p.encode(to: encoder)
        case .data(let p):  try p.encode(to: encoder)
        case .file(let p):  try p.encode(to: encoder)
        }
    }
}

// MARK: - Message / Task / Artifact

/// v0.3 Message  — `{messageId, role, parts, taskId?, contextId?, metadata?}`
struct V0Message: Codable, Sendable {
    var messageId: String
    var role: V0Role
    var parts: [V0Part]
    var taskId: String?
    var contextId: String?
    var metadata: [String: AnyCodable]?
}

/// v0.3 TaskStatus  — `{state, message?, timestamp?}`
struct V0TaskStatus: Codable, Sendable {
    var state: V0TaskState
    var message: V0Message?
    var timestamp: String?
}

/// v0.3 Artifact  — `{artifactId, name?, description?, parts, metadata?, index?}`
struct V0Artifact: Codable, Sendable {
    var artifactId: String?
    var name: String?
    var description: String?
    var parts: [V0Part]
    var metadata: [String: AnyCodable]?
    var index: Int?
    var append: Bool?
    var lastChunk: Bool?
}

/// v0.3 Task  — `{id, sessionId?, status, artifacts?, history?, metadata?}`
struct V0Task: Codable, Sendable {
    var id: String
    var sessionId: String?
    var status: V0TaskStatus
    var artifacts: [V0Artifact]?
    var history: [V0Message]?
    var metadata: [String: AnyCodable]?
}

// MARK: - Request / Response types

/// v0.3 MessageSendConfig (embedded in SendMessageParams).
struct V0MessageSendConfig: Codable, Sendable {
    /// Inverse of v1.0 `returnImmediately`.  `true` = wait for terminal state.
    var blocking: Bool?
    var historyLength: Int?
    var acceptedOutputModes: [String]?
    var pushNotificationConfig: V0PushNotificationConfig?
}

/// v0.3 params for `message/send` and `message/stream`.
struct V0MessageSendParams: Codable, Sendable {
    var message: V0Message
    var configuration: V0MessageSendConfig?
}

/// v0.3 params for `tasks/get`.
struct V0TaskQueryParams: Codable, Sendable {
    var id: String
    var historyLength: Int?
    var metadata: [String: AnyCodable]?
}

/// v0.3 params for `tasks/cancel` and `tasks/resubscribe`.
struct V0TaskIDParams: Codable, Sendable {
    var id: String
    var metadata: [String: AnyCodable]?
}

// MARK: - Push Notification types

/// v0.3 push notification authentication info.
struct V0AuthenticationInfo: Codable, Sendable {
    var schemes: [String]
    var credentials: String?
}

/// v0.3 push notification config (inline in MessageSendConfig).
struct V0PushNotificationConfig: Codable, Sendable {
    var url: String
    var token: String?
    var authentication: V0AuthenticationInfo?
}

/// v0.3 TaskPushNotificationConfig (standalone, with task ID).
struct V0TaskPushNotificationConfig: Codable, Sendable {
    var id: String
    var taskId: String
    var pushNotificationConfig: V0PushNotificationConfig

    enum CodingKeys: String, CodingKey {
        case id
        case taskId
        case pushNotificationConfig
    }
}

/// v0.3 SetTaskPushNotificationConfigParams.
struct V0SetPushNotificationConfigParams: Codable, Sendable {
    var id: String
    var pushNotificationConfig: V0PushNotificationConfig
}

/// v0.3 GetTaskPushNotificationConfigParams.
struct V0GetPushNotificationConfigParams: Codable, Sendable {
    var id: String
}

/// v0.3 TaskStatusUpdateEvent (streaming).
struct V0TaskStatusUpdateEvent: Codable, Sendable {
    var id: String
    var status: V0TaskStatus
    var final: Bool?
    var metadata: [String: AnyCodable]?
}

/// v0.3 TaskArtifactUpdateEvent (streaming).
struct V0TaskArtifactUpdateEvent: Codable, Sendable {
    var id: String
    var artifact: V0Artifact
    var metadata: [String: AnyCodable]?
}

// MARK: - AgentCard compat types

/// v0.3 additional interface entry in the agent card.
struct V0AdditionalInterface: Codable, Sendable {
    var url: String
    var transport: String?
}

/// v0.3 security scheme (only `type` discrimination needed for conversion).
struct V0SecurityScheme: Codable, Sendable {
    var type: String?
    var `in`: String?
    var name: String?
    var scheme: String?
    var bearerFormat: String?
    var flows: AnyCodable?
    var openIdConnectUrl: String?
}

/// v0.3 skill.
struct V0AgentSkill: Codable, Sendable {
    var id: String
    var name: String
    var description: String?
    var tags: [String]?
    var examples: [String]?
    var inputModes: [String]?
    var outputModes: [String]?
}

/// Compat AgentCard struct that can parse both v0.3 and v1.0 JSON.
///
/// Mirrors Go's `agentCardCompat` in `a2acompat/a2av0/agentcard.go`.
///
/// When the JSON contains `supportedInterfaces` (v1.0 field), those are used
/// directly and the v0.3 fields are ignored. Otherwise the v0.3 flat fields
/// `url` / `preferredTransport` / `additionalInterfaces` are used to build
/// the v1.0 equivalent.
struct V0AgentCardCompat: Codable, Sendable {
    // v0.3 fields
    var url: String?
    var protocolVersion: String?
    var preferredTransport: String?
    var additionalInterfaces: [V0AdditionalInterface]?
    var supportsAuthenticatedExtendedCard: Bool?
    var securitySchemes: [String: V0SecurityScheme]?

    // Shared / v1.0 fields
    var name: String?
    var description: String?
    var version: String?
    var documentationUrl: String?
    var capabilities: V0AgentCapabilities?
    var skills: [V0AgentSkill]?
    var defaultInputModes: [String]?
    var defaultOutputModes: [String]?

    // v1.0-only — presence determines parser branch
    var supportedInterfaces: [AnyCodable]?
    var securityRequirements: [AnyCodable]?
}

/// v0.3 agent capabilities.
struct V0AgentCapabilities: Codable, Sendable {
    var streaming: Bool?
    var pushNotifications: Bool?
    var stateTransitionHistory: Bool?
}

// MARK: - AnyCodable helper
//
// A lightweight type-erased Codable container used for fields whose JSON
// structure we don't need to inspect (metadata, arbitrary extension data).

/// A Codable wrapper for arbitrary JSON values.
///
/// Supports JSON null, bool, int, double, string, array and object.
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else if let a = try? container.decode([AnyCodable].self) {
            value = a.map { $0.value }
        } else if let o = try? container.decode([String: AnyCodable].self) {
            value = o.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let a as [Any]:
            try container.encode(a.map { AnyCodable($0) })
        case let o as [String: Any]:
            try container.encode(o.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
