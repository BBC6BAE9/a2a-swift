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

// MARK: - TenantTransportDecorator

/// An ``A2ATransport`` decorator that injects a tenant identifier into every
/// outgoing request.
///
/// The tenant value is resolved with the following priority (first non-empty wins):
///
/// 1. The `tenant` field already present in the JSON-RPC `params` dictionary.
/// 2. The static ``tenant`` field set on this decorator at construction time.
/// 3. The ``TenantID/current`` task-local value bound by the caller.
///
/// If none of the above yields a tenant the request is forwarded unchanged.
///
/// All other methods (`get`, `close`) are forwarded to the underlying transport
/// without modification.
///
/// Mirrors Go's `tenantTransportDecorator` in `a2aclient/transport.go`.
///
/// ## Example
///
/// ```swift
/// // Always use "acme" as the tenant, regardless of task-local.
/// let transport = TenantTransportDecorator(base: SseTransport(url: url), tenant: "acme")
///
/// // Inherit tenant from task-local at call time.
/// let transport = TenantTransportDecorator(base: SseTransport(url: url))
/// await TenantID.$current.withValue("acme") {
///     _ = try await transport.send(request)
/// }
/// ```
public final class TenantTransportDecorator: A2ATransport, @unchecked Sendable {

    // MARK: - Properties

    /// The wrapped transport that handles the actual network I/O.
    public let base: any A2ATransport

    /// A static tenant string to inject when no tenant is present in the request.
    ///
    /// When empty the decorator falls back to ``TenantID/current``.
    public let tenant: String

    // MARK: - Initialiser

    /// Creates a ``TenantTransportDecorator``.
    ///
    /// - Parameters:
    ///   - base: The underlying ``A2ATransport`` to delegate to.
    ///   - tenant: An optional static tenant string.  When omitted (or empty)
    ///     the decorator reads ``TenantID/current`` from the task context at
    ///     the time of each request.
    public init(base: any A2ATransport, tenant: String = "") {
        self.base = base
        self.tenant = tenant
    }

    // MARK: - A2ATransport

    public var authParams: ServiceParams { base.authParams }

    public func get(path: String, params: ServiceParams) async throws -> [String: Any] {
        try await base.get(path: path, params: params)
    }

    public func send(
        _ request: [String: Any],
        path: String,
        params: ServiceParams
    ) async throws -> [String: Any] {
        let injected = injectTenant(into: request)
        return try await base.send(injected, path: path, params: params)
    }

    public func sendStream(
        _ request: [String: Any],
        params: ServiceParams
    ) -> AsyncThrowingStream<[String: Any], Error> {
        let injected = injectTenant(into: request)
        return base.sendStream(injected, params: params)
    }

    public func close() {
        base.close()
    }

    // MARK: - Tenant injection

    /// Returns a copy of `request` with the `params.tenant` field set.
    ///
    /// The value is chosen with the priority described on the type.
    /// If no tenant can be resolved the request is returned unchanged.
    private func injectTenant(into request: [String: Any]) -> [String: Any] {
        // Extract the params sub-dictionary, or start with an empty one.
        var params = (request["params"] as? [String: Any]) ?? [:]

        // Determine effective tenant using priority order.
        let effective = resolvedTenant(current: params["tenant"] as? String ?? "")
        guard !effective.isEmpty else { return request }

        // Inject and return the modified request.
        params["tenant"] = effective
        var updated = request
        updated["params"] = params
        return updated
    }

    /// Resolves the tenant to use, following Go's priority rules.
    ///
    /// - Parameter current: The tenant value already present in the request params.
    /// - Returns: The resolved tenant, or empty string if none is available.
    private func resolvedTenant(current: String) -> String {
        if !current.isEmpty { return current }
        if !tenant.isEmpty { return tenant }
        return TenantID.current ?? ""  // reads @TaskLocal TenantID.current
    }
}
