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

// MARK: - TenantID

/// A namespace for task-local tenant identifier storage.
///
/// Attach a tenant string to the current task's local context using
/// ``TenantID/$current``; the ``TenantTransportDecorator`` reads this value
/// automatically and injects it into every outgoing request.
///
/// Mirrors Go's `a2a.TenantFrom` / `a2a.AttachTenant` context helpers in
/// `a2a/tenant.go`.
///
/// ## Example
///
/// ```swift
/// // Attach a tenant ID before calling any A2A methods.
/// await TenantID.$current.withValue("acme-corp") {
///     let response = try await client.messageSend(myMessage)
/// }
/// ```
public enum TenantID {

    /// Task-local storage for the current tenant identifier.
    ///
    /// Set this value using `await TenantID.$current.withValue("…") { … }`
    /// and read it anywhere inside the same task tree via `TenantID.current`.
    ///
    /// Mirrors Go's context-based `AttachTenant` / `TenantFrom`
    /// in `a2a/tenant.go`.
    @TaskLocal public static var current: String? = nil
}
