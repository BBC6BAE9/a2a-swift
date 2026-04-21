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

// MARK: - V0Conversions
//
// Bidirectional conversions between v0.3 Codable wire types (``V0*``) and
// v1.0 SwiftProtobuf types.  All functions are package-internal (no `public`).
//
// Mirrors Go's `a2acompat/a2av0/conversions.go`.

// MARK: - ServiceParams ↔ header remapping

/// The v0.3 header name used instead of the v1.0 ``SvcParamExtensions`` header.
let v0ExtensionsHeader = "x-a2a-extensions"

/// Maps v1.0 ``ServiceParams`` to v0.3 wire headers.
///
/// Renames `a2a-extensions` → `x-a2a-extensions` (lower-cased).
/// Mirrors Go's `FromServiceParams` in `conversions.go`.
func fromServiceParams(_ params: ServiceParams) -> ServiceParams {
    var out = ServiceParams()
    for (key, values) in params.asDictionary() {
        let mapped = key == SvcParamExtensions.lowercased() ? v0ExtensionsHeader : key
        out.append(mapped, values)
    }
    return out
}

/// Maps v0.3 wire headers back to v1.0 ``ServiceParams``.
///
/// Renames `x-a2a-extensions` → `a2a-extensions` (lower-cased).
/// Mirrors Go's `ToServiceParams` in `conversions.go`.
func toServiceParams(_ params: ServiceParams) -> ServiceParams {
    var out = ServiceParams()
    for (key, values) in params.asDictionary() {
        let mapped = key == v0ExtensionsHeader ? SvcParamExtensions.lowercased() : key
        out.append(mapped, values)
    }
    return out
}

// MARK: - Part conversions

/// Converts a v1.0 ``Part`` to a v0.3 ``V0Part``.
func fromV1Part(_ part: Part) -> V0Part {
    let meta = structToDict(part.hasMetadata ? part.metadata : nil)
    let codableMeta = meta.isEmpty ? nil : meta.mapValues { AnyCodable($0) }

    switch part.content {
    case .text(let text):
        var p = V0TextPart(text: text)
        if !part.mediaType.isEmpty {
            var m = codableMeta ?? [:]
            m["mimeType"] = AnyCodable(part.mediaType)
            p.metadata = m
        } else {
            p.metadata = codableMeta
        }
        return .text(p)

    case .raw(let data):
        // Binary file: encode as base64.
        let fc = V0FilePart.V0FileContent(
            bytes: data.base64EncodedString(),
            mimeType: part.mediaType.isEmpty ? nil : part.mediaType,
            name: part.filename.isEmpty ? nil : part.filename
        )
        var p = V0FilePart(file: fc)
        p.metadata = codableMeta
        return .file(p)

    case .url(let url):
        // URI-based file.
        let fc = V0FilePart.V0FileContent(
            uri: url,
            mimeType: part.mediaType.isEmpty ? nil : part.mediaType,
            name: part.filename.isEmpty ? nil : part.filename
        )
        var p = V0FilePart(file: fc)
        p.metadata = codableMeta
        return .file(p)

    case .data(let value):
        // Convert Google_Protobuf_Value → native Any → AnyCodable.
        let anyValue = protobufValueToAny(value)
        var p = V0DataPart(data: AnyCodable(anyValue))
        p.metadata = codableMeta
        return .data(p)

    case nil:
        // Empty part → empty text.
        return .text(V0TextPart(text: ""))
    }
}

/// Converts a v0.3 ``V0Part`` to a v1.0 ``Part``.
func toV1Part(_ v0Part: V0Part) -> Part {
    var part = Part()
    switch v0Part {
    case .text(let p):
        part.text = p.text
        if let meta = p.metadata {
            if let mime = meta["mimeType"]?.value as? String {
                part.mediaType = mime
            }
        }

    case .data(let p):
        // Compat data parts may have been wrapped in {"value": ...} by the Go SDK.
        var rawValue = p.data.value
        if let dict = rawValue as? [String: Any], let inner = dict["value"] {
            rawValue = inner
        }
        part.data = anyToProtobufValue(rawValue)

    case .file(let p):
        let fc = p.file
        if let mimeType = fc.mimeType { part.mediaType = mimeType }
        if let name = fc.name { part.filename = name }
        if let bytes = fc.bytes, let data = Data(base64Encoded: bytes) {
            part.raw = data
        } else if let uri = fc.uri {
            part.url = uri
        }
    }
    return part
}

// MARK: - Message conversions

/// Converts a v1.0 ``Message`` to a v0.3 ``V0Message``.
func fromV1Message(_ msg: Message) -> V0Message {
    V0Message(
        messageId: msg.messageID,
        role: msg.role == .user ? .user : .agent,
        parts: msg.parts.map { fromV1Part($0) },
        taskId: msg.taskID.isEmpty ? nil : msg.taskID,
        contextId: msg.contextID.isEmpty ? nil : msg.contextID,
        metadata: structToDict(msg.hasMetadata ? msg.metadata : nil)
            .isEmpty ? nil : structToDict(msg.hasMetadata ? msg.metadata : nil)
            .mapValues { AnyCodable($0) }
    )
}

/// Converts a v0.3 ``V0Message`` to a v1.0 ``Message``.
func toV1Message(_ v0Msg: V0Message) -> Message {
    var msg = Message()
    msg.messageID = v0Msg.messageId
    msg.role = v0Msg.role == .user ? .user : .agent
    msg.parts = v0Msg.parts.map { toV1Part($0) }
    if let tid = v0Msg.taskId, !tid.isEmpty { msg.taskID = tid }
    if let cid = v0Msg.contextId, !cid.isEmpty { msg.contextID = cid }
    return msg
}

// MARK: - TaskStatus conversions

/// Converts a v1.0 ``TaskStatus`` to a v0.3 ``V0TaskStatus``.
func fromV1TaskStatus(_ status: TaskStatus) -> V0TaskStatus {
    let v0State: V0TaskState
    switch status.state {
    case .submitted:     v0State = .submitted
    case .working:       v0State = .working
    case .inputRequired: v0State = .inputRequired
    case .completed:     v0State = .completed
    case .canceled:      v0State = .canceled
    case .failed:        v0State = .failed
    case .rejected:      v0State = .rejected
    case .authRequired:  v0State = .authRequired
    default:             v0State = .unknown
    }
    let v0Msg = status.hasMessage ? fromV1Message(status.message) : nil
    return V0TaskStatus(state: v0State, message: v0Msg)
}

/// Converts a v0.3 ``V0TaskStatus`` to a v1.0 ``TaskStatus``.
func toV1TaskStatus(_ v0Status: V0TaskStatus) -> TaskStatus {
    var status = TaskStatus()
    switch v0Status.state {
    case .submitted:     status.state = .submitted
    case .working:       status.state = .working
    case .inputRequired: status.state = .inputRequired
    case .completed:     status.state = .completed
    case .canceled:      status.state = .canceled
    case .failed:        status.state = .failed
    case .rejected:      status.state = .rejected
    case .authRequired:  status.state = .authRequired
    case .unknown:       status.state = .unspecified
    }
    if let v0Msg = v0Status.message {
        status.message = toV1Message(v0Msg)
    }
    return status
}

// MARK: - Artifact conversions

/// Converts a v1.0 ``Artifact`` to a v0.3 ``V0Artifact``.
func fromV1Artifact(_ artifact: Artifact) -> V0Artifact {
    V0Artifact(
        artifactId: artifact.artifactID.isEmpty ? nil : artifact.artifactID,
        name: artifact.name.isEmpty ? nil : artifact.name,
        description: artifact.description_p.isEmpty ? nil : artifact.description_p,
        parts: artifact.parts.map { fromV1Part($0) }
    )
}

/// Converts a v0.3 ``V0Artifact`` to a v1.0 ``Artifact``.
func toV1Artifact(_ v0Artifact: V0Artifact) -> Artifact {
    var artifact = Artifact()
    if let aid = v0Artifact.artifactId { artifact.artifactID = aid }
    if let name = v0Artifact.name { artifact.name = name }
    if let desc = v0Artifact.description { artifact.description_p = desc }
    artifact.parts = v0Artifact.parts.map { toV1Part($0) }
    return artifact
}

// MARK: - Task conversions

/// Converts a v1.0 ``Task`` to a v0.3 ``V0Task``.
func fromV1Task(_ task: Task) -> V0Task {
    V0Task(
        id: task.id,
        sessionId: task.contextID.isEmpty ? nil : task.contextID,
        status: fromV1TaskStatus(task.status),
        artifacts: task.artifacts.isEmpty ? nil : task.artifacts.map { fromV1Artifact($0) },
        history: task.history.isEmpty ? nil : task.history.map { fromV1Message($0) }
    )
}

/// Converts a v0.3 ``V0Task`` to a v1.0 ``Task``.
func toV1Task(_ v0Task: V0Task) -> Task {
    var task = Task()
    task.id = v0Task.id
    if let sid = v0Task.sessionId { task.contextID = sid }
    task.status = toV1TaskStatus(v0Task.status)
    if let arts = v0Task.artifacts {
        task.artifacts = arts.map { toV1Artifact($0) }
    }
    if let history = v0Task.history {
        task.history = history.map { toV1Message($0) }
    }
    return task
}

// MARK: - TaskPushNotificationConfig conversions

/// Converts a v1.0 ``TaskPushNotificationConfig`` to a v0.3
/// ``V0TaskPushNotificationConfig``.
///
/// Note: The v1.0 proto stores push notification fields (url, token,
/// authentication) directly on ``TaskPushNotificationConfig`` rather than in a
/// nested message, so we reconstruct a ``V0PushNotificationConfig`` from those
/// flattened fields.
func fromV1TaskPushConfig(_ config: TaskPushNotificationConfig) -> V0TaskPushNotificationConfig {
    var auth: V0AuthenticationInfo? = nil
    if config.hasAuthentication {
        auth = V0AuthenticationInfo(
            schemes: [config.authentication.scheme],
            credentials: config.authentication.credentials.isEmpty
                ? nil : config.authentication.credentials
        )
    }
    let v0Push = V0PushNotificationConfig(
        url: config.url,
        token: config.token.isEmpty ? nil : config.token,
        authentication: auth
    )
    return V0TaskPushNotificationConfig(
        id: config.id,
        taskId: config.taskID,
        pushNotificationConfig: v0Push
    )
}

/// Converts a v0.3 ``V0TaskPushNotificationConfig`` to a v1.0
/// ``TaskPushNotificationConfig``.
func toV1TaskPushConfig(_ v0Config: V0TaskPushNotificationConfig) -> TaskPushNotificationConfig {
    var config = TaskPushNotificationConfig()
    config.id = v0Config.id
    config.taskID = v0Config.taskId
    let push = v0Config.pushNotificationConfig
    config.url = push.url
    if let token = push.token { config.token = token }
    if let auth = push.authentication, let scheme = auth.schemes.first {
        var authInfo = AuthenticationInfo()
        authInfo.scheme = scheme
        if let creds = auth.credentials { authInfo.credentials = creds }
        config.authentication = authInfo
    }
    return config
}

// MARK: - Streaming event conversions

/// Converts a v0.3 ``V0TaskStatusUpdateEvent`` to a v1.0
/// ``TaskStatusUpdateEvent``.
func toV1StatusUpdateEvent(_ ev: V0TaskStatusUpdateEvent) -> TaskStatusUpdateEvent {
    var event = TaskStatusUpdateEvent()
    event.taskID = ev.id
    event.status = toV1TaskStatus(ev.status)
    return event
}

/// Converts a v0.3 ``V0TaskArtifactUpdateEvent`` to a v1.0
/// ``TaskArtifactUpdateEvent``.
func toV1ArtifactUpdateEvent(_ ev: V0TaskArtifactUpdateEvent) -> TaskArtifactUpdateEvent {
    var event = TaskArtifactUpdateEvent()
    event.taskID = ev.id
    event.artifact = toV1Artifact(ev.artifact)
    event.append = ev.artifact.append ?? false
    event.lastChunk = ev.artifact.lastChunk ?? false
    return event
}

// MARK: - SendMessage request conversion

/// Converts a v1.0 ``SendMessageRequest`` to v0.3 ``V0MessageSendParams``.
///
/// The inverse of `returnImmediately` is placed into `blocking`:
/// `blocking = !returnImmediately`  (v1 `returnImmediately=false` → v0 `blocking=true`).
func fromV1SendMessageRequest(_ req: SendMessageRequest) -> V0MessageSendParams {
    let blocking: Bool? = req.configuration.returnImmediately ? false : true
    var cfg = V0MessageSendConfig(
        blocking: blocking,
        historyLength: req.configuration.hasHistoryLength
            ? Int(req.configuration.historyLength) : nil,
        acceptedOutputModes: req.configuration.acceptedOutputModes.isEmpty
            ? nil : req.configuration.acceptedOutputModes
    )
    if req.configuration.hasTaskPushNotificationConfig {
        let tpnc = req.configuration.taskPushNotificationConfig
        // v1 TaskPushNotificationConfig stores url/token/authentication directly.
        var auth: V0AuthenticationInfo? = nil
        if tpnc.hasAuthentication {
            auth = V0AuthenticationInfo(
                schemes: [tpnc.authentication.scheme],
                credentials: tpnc.authentication.credentials.isEmpty
                    ? nil : tpnc.authentication.credentials
            )
        }
        cfg.pushNotificationConfig = V0PushNotificationConfig(
            url: tpnc.url,
            token: tpnc.token.isEmpty ? nil : tpnc.token,
            authentication: auth
        )
    }
    return V0MessageSendParams(
        message: fromV1Message(req.message),
        configuration: cfg
    )
}

// MARK: - Streaming event JSON → v1 helper

/// Attempts to decode a raw JSON dictionary (from a v0.3 SSE event) into a
/// v1.0 SwiftProtobuf type.
///
/// The v0.3 streaming protocol sends either a TaskStatusUpdateEvent or a
/// TaskArtifactUpdateEvent.  We detect which by the presence of `"status"` vs
/// `"artifact"` keys.  A final Message (non-task result) is also possible.
///
/// Returns `nil` if the event doesn't match any known shape.
func decodeV0StreamEvent(_ dict: [String: Any]) -> StreamEventResult? {
    guard !dict.isEmpty else { return nil }
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let codable = try? JSONDecoder().decode(AnyCodable.self, from: data)
    else { return nil }
    _ = codable  // suppress unused-variable warning

    if dict["status"] != nil {
        // TaskStatusUpdateEvent
        guard let data2 = try? JSONSerialization.data(withJSONObject: dict),
              let ev = try? JSONDecoder().decode(V0TaskStatusUpdateEvent.self, from: data2)
        else { return nil }
        return .statusUpdate(toV1StatusUpdateEvent(ev))
    }

    if dict["artifact"] != nil {
        // TaskArtifactUpdateEvent
        guard let data2 = try? JSONSerialization.data(withJSONObject: dict),
              let ev = try? JSONDecoder().decode(V0TaskArtifactUpdateEvent.self, from: data2)
        else { return nil }
        return .artifactUpdate(toV1ArtifactUpdateEvent(ev))
    }

    if dict["parts"] != nil, dict["messageId"] != nil {
        // Message (non-task result)
        guard let data2 = try? JSONSerialization.data(withJSONObject: dict),
              let msg = try? JSONDecoder().decode(V0Message.self, from: data2)
        else { return nil }
        return .message(toV1Message(msg))
    }

    return nil
}

/// Discriminated result of decoding a v0.3 SSE event.
enum StreamEventResult: Sendable {
    case statusUpdate(TaskStatusUpdateEvent)
    case artifactUpdate(TaskArtifactUpdateEvent)
    case message(Message)
}

// MARK: - Protobuf value helpers (internal)

/// Converts a ``Google_Protobuf_Struct`` to a `[String: Any]` dictionary.
private func structToDict(_ s: Google_Protobuf_Struct?) -> [String: Any] {
    guard let s = s else { return [:] }
    return s.fields.compactMapValues { protobufValueToAny($0) }
}

/// Converts a ``Google_Protobuf_Value`` to a native `Any`.
func protobufValueToAny(_ value: Google_Protobuf_Value) -> Any {
    switch value.kind {
    case .nullValue:    return NSNull()
    case .boolValue(let b): return b
    case .numberValue(let n): return n
    case .stringValue(let s): return s
    case .listValue(let l):
        return l.values.map { protobufValueToAny($0) }
    case .structValue(let s):
        return s.fields.compactMapValues { protobufValueToAny($0) }
    case nil:
        return NSNull()
    }
}

/// Converts a native `Any` to a ``Google_Protobuf_Value``.
func anyToProtobufValue(_ any: Any) -> Google_Protobuf_Value {
    var v = Google_Protobuf_Value()
    switch any {
    case is NSNull:
        v.nullValue = .nullValue
    case let b as Bool:
        v.boolValue = b
    case let n as Int:
        v.numberValue = Double(n)
    case let n as Double:
        v.numberValue = n
    case let s as String:
        v.stringValue = s
    case let a as [Any]:
        var list = Google_Protobuf_ListValue()
        list.values = a.map { anyToProtobufValue($0) }
        v.listValue = list
    case let o as [String: Any]:
        var struct_ = Google_Protobuf_Struct()
        struct_.fields = o.compactMapValues { anyToProtobufValue($0) }
        v.structValue = struct_
    default:
        v.nullValue = .nullValue
    }
    return v
}
