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

// MARK: - A2ATransportError

/// Errors thrown by ``A2ATransport`` implementations during communication
/// with an A2A server.
///
/// Mirrors Flutter `sealed class A2AException` in `genui_a2a/client/a2a_exception.dart`.
///
/// Uses a Swift `enum` with associated values instead of Flutter's `@freezed sealed class`,
/// as Swift enums provide equivalent exhaustive pattern-matching semantics.
public enum A2ATransportError: Error, Sendable, Equatable {

    // MARK: JSON-RPC Errors

    /// A JSON-RPC error returned by the server.
    ///
    /// The server responded with a JSON-RPC error object, indicating a problem
    /// with the request at the A2A protocol level.
    ///
    /// - Parameters:
    ///   - code: The integer error code as defined by JSON-RPC 2.0 or A2A-specific codes.
    ///   - message: A human-readable description of the error.
    case jsonRpc(code: Int, message: String)

    /// The requested task was not found on the server.
    case taskNotFound(message: String)

    /// The requested task cannot be cancelled.
    case taskNotCancelable(message: String)

    /// Push notifications are not supported by the server.
    case pushNotificationNotSupported(message: String)

    /// Push notification configuration was not found.
    case pushNotificationConfigNotFound(message: String)

    /// The server does not support the extended agent card capability.
    ///
    /// Returned by ``A2AClient/getExtendedAgentCard()`` when the cached
    /// ``AgentCard`` has `capabilities.extendedAgentCard == false`.
    ///
    /// Mirrors Go's `a2a.ErrExtendedCardNotConfigured` in
    /// `a2aclient/client.go`.
    case extendedCardNotConfigured

    /// The A2A protocol version specified in the request is not supported by the server.
    ///
    /// JSON-RPC error code: `-32009`.
    ///
    /// Mirrors Go's `a2a.ErrVersionNotSupported`.
    case versionNotSupported(message: String)

    /// The client requested use of an extension marked as required, but the server
    /// does not support that extension.
    ///
    /// JSON-RPC error code: `-32008`.
    ///
    /// Mirrors Go's `a2a.ErrExtensionSupportRequired`.
    case extensionSupportRequired(message: String)

    /// The request does not have valid authentication credentials (HTTP 401).
    ///
    /// JSON-RPC error code: `-31401`.
    ///
    /// Mirrors Go's `a2a.ErrUnauthenticated`.
    case unauthenticated(message: String)

    /// The caller does not have permission to execute the specified operation (HTTP 403).
    ///
    /// JSON-RPC error code: `-31403`.
    ///
    /// Mirrors Go's `a2a.ErrUnauthorized`.
    case unauthorized(message: String)

    /// There is an incompatibility between the requested and supported content types (HTTP 415).
    ///
    /// JSON-RPC error code: `-32005`.
    ///
    /// Mirrors Go's `a2a.ErrUnsupportedContentType`.
    case unsupportedContentType(message: String)

    /// The agent returned a response that does not conform to the A2A protocol.
    ///
    /// For example, an execution that finished without producing any events,
    /// or an unexpected event type in a streaming response.
    ///
    /// JSON-RPC error code: `-32006`.
    ///
    /// Mirrors Go's `a2a.ErrInvalidAgentResponse`.
    case invalidAgentResponse(message: String)

    // MARK: Transport-Level Errors

    /// An HTTP request failed with a non-2xx status code.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code (e.g. 404, 500).
    ///   - reason: An optional human-readable reason phrase.
    case http(statusCode: Int, reason: String?)

    /// A network connectivity issue occurred.
    ///
    /// The connection to the server could not be established or was interrupted.
    case network(message: String)

    /// The server response could not be parsed.
    ///
    /// For example, malformed JSON or an unexpected response structure.
    case parsing(message: String)

    /// The operation is not supported by this transport implementation.
    ///
    /// For example, calling `sendStream` on a non-streaming ``HttpTransport``.
    case unsupportedOperation(message: String)
}

// MARK: - LocalizedError

extension A2ATransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .jsonRpc(let code, let message):
            return "JSON-RPC error \(code): \(message)"
        case .taskNotFound(let message):
            return "Task not found: \(message)"
        case .taskNotCancelable(let message):
            return "Task not cancelable: \(message)"
        case .pushNotificationNotSupported(let message):
            return "Push notification not supported: \(message)"
        case .pushNotificationConfigNotFound(let message):
            return "Push notification config not found: \(message)"
        case .extendedCardNotConfigured:
            return "Extended agent card is not configured"
        case .versionNotSupported(let message):
            return "Version not supported: \(message)"
        case .extensionSupportRequired(let message):
            return "Extension support required: \(message)"
        case .unauthenticated(let message):
            return "Unauthenticated: \(message)"
        case .unauthorized(let message):
            return "Unauthorized: \(message)"
        case .unsupportedContentType(let message):
            return "Unsupported content type: \(message)"
        case .invalidAgentResponse(let message):
            return "Invalid agent response: \(message)"
        case .http(let statusCode, let reason):
            return "HTTP error \(statusCode)\(reason.map { ": \($0)" } ?? "")"
        case .network(let message):
            return "Network error: \(message)"
        case .parsing(let message):
            return "Parsing error: \(message)"
        case .unsupportedOperation(let message):
            return "Unsupported operation: \(message)"
        }
    }
}
