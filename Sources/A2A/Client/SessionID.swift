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

// MARK: - SessionID

/// A unique identifier for an authenticated session.
///
/// Attach a session ID to the current task's local context using
/// ``SessionID/withValue(_:operation:)``; retrieve it inside a handler with
/// ``SessionID/current``.
///
/// ``AuthHandler`` reads this value automatically to look up credentials in
/// the ``CredentialsService`` for the active session.
///
/// Mirrors Go's `type SessionID string` and `AttachSessionID` / `SessionIDFrom`
/// in `a2aclient/auth.go`.
///
/// ## Example
///
/// ```swift
/// // Attach a session ID before calling any A2A methods.
/// await SessionID.$current.withValue("session-abc") {
///     let response = try await client.messageSend(myMessage)
/// }
/// ```
public typealias SessionID = String

// MARK: - TaskLocal storage

extension SessionID {

    /// Task-local storage for the current session identifier.
    ///
    /// Set this value using `await SessionID.$current.withValue("…") { … }`
    /// and read it anywhere inside the same task tree via `SessionID.current`.
    ///
    /// Mirrors Go's context-based `AttachSessionID` / `SessionIDFrom`
    /// in `a2aclient/auth.go`.
    @TaskLocal public static var current: SessionID? = nil
}
