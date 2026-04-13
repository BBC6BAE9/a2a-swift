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

// MARK: - AuthenticationInfo

/// Defines authentication details, used for push notification endpoints.
///
/// The `scheme` is a single HTTP Authentication Scheme name from the
/// [IANA registry](https://www.iana.org/assignments/http-authschemes/)
/// (e.g. `"Bearer"`, `"Basic"`, `"Digest"`). Scheme names are
/// case-insensitive per RFC 9110 §11.1.
///
/// Matches the proto3 `AuthenticationInfo` message in `specification/a2a.proto`.
public struct AuthenticationInfo: Codable, Sendable, Equatable {

    /// HTTP Authentication Scheme (e.g., `"Bearer"`, `"Basic"`, `"Digest"`).
    public let scheme: String

    /// Push Notification credentials. Format depends on the scheme
    /// (e.g., a token string for Bearer).
    public let credentials: String?

    public init(scheme: String, credentials: String? = nil) {
        self.scheme = scheme
        self.credentials = credentials
    }
}

// MARK: - TaskPushNotificationConfig

/// A container associating a push notification configuration with a specific task.
///
/// Matches the proto3 `TaskPushNotificationConfig` message in
/// `specification/a2a.proto`.
public struct TaskPushNotificationConfig: Codable, Sendable, Equatable {

    /// Optional. Tenant ID.
    public let tenant: String?

    /// A unique identifier (e.g. UUID) for this push notification configuration.
    public let id: String?

    /// The unique identifier (e.g. UUID) of the task this config is associated with.
    public let taskId: String

    /// The callback URL where the agent should send push notifications.
    public let url: String

    /// A unique token for this task or session to validate incoming push notifications.
    public let token: String?

    /// Optional authentication details for the agent to use when calling the
    /// notification URL.
    public let authentication: AuthenticationInfo?

    public init(
        tenant: String? = nil,
        id: String? = nil,
        taskId: String,
        url: String,
        token: String? = nil,
        authentication: AuthenticationInfo? = nil
    ) {
        self.tenant = tenant
        self.id = id
        self.taskId = taskId
        self.url = url
        self.token = token
        self.authentication = authentication
    }
}

// MARK: - PushNotificationConfig (deprecated alias)

/// Backward-compatible type alias for push notification configuration.
///
/// New code should use ``TaskPushNotificationConfig`` directly.
@available(*, deprecated, renamed: "TaskPushNotificationConfig")
public typealias PushNotificationConfig = TaskPushNotificationConfig
