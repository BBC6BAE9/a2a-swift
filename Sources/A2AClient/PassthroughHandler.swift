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

// MARK: - PassthroughHandler

/// A no-op base implementation of ``A2AHandler``.
///
/// Subclass or use this as a mixin when you only need to override one of the
/// two handler methods. Both default implementations simply return their
/// input unchanged.
///
/// ## Example — only intercept requests
///
/// ```swift
/// final class TokenInjector: PassthroughHandler {
///     let token: String
///     init(token: String) { self.token = token }
///
///     override func handleRequest(_ request: [String: Any]) async throws -> [String: Any] {
///         // inject token into params, then pass through
///         var req = request
///         if var params = req["params"] as? [String: Any] {
///             params["_auth"] = token
///             req["params"] = params
///         }
///         return req
///     }
///     // handleResponse: no override needed — defaults to passthrough
/// }
/// ```
///
/// Mirrors Go's `PassthroughInterceptor` in `a2aclient/middleware.go`.
open class PassthroughHandler: A2AHandler, @unchecked Sendable {

    public init() {}

    /// Default implementation: returns `request` unchanged.
    open func handleRequest(_ request: [String: Any]) async throws -> [String: Any] {
        return request
    }

    /// Default implementation: returns `response` unchanged.
    open func handleResponse(_ response: [String: Any]) async throws -> [String: Any] {
        return response
    }
}
