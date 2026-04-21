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

// MARK: - Protocol bindings

/// Well-known `protocolBinding` values used in ``AgentInterface``.
///
/// Mirrors the string constants from the A2A specification.
public enum A2AProtocolBinding {
    /// Standard JSON-RPC 2.0 over HTTP (default A2A transport).
    public static let jsonRPC = "JSON_RPC"
    /// RESTful HTTP without JSON-RPC envelopes.
    public static let httpJSON = "HTTP_JSON"
}

// MARK: - A2ATransportFactory

/// Creates an ``A2ATransport`` by reading the ``AgentCard/supportedInterfaces``
/// field and selecting the best available protocol.
///
/// ## Selection rules
///
/// 1. Collect every ``AgentInterface`` whose `protocolBinding` matches a
///    registered binding (``A2AProtocolBinding/jsonRPC`` or
///    ``A2AProtocolBinding/httpJSON``).
/// 2. Sort candidates: newer `protocolVersion` (semver) first; ties broken by
///    client preference (JSON-RPC before REST).
/// 3. Pick the first candidate and create the matching transport for its `url`.
/// 4. Wrap the transport in a ``TenantTransportDecorator`` so tenant
///    propagation works transparently.
///
/// When no ``AgentInterface`` matches, falls back to a plain ``SseTransport``
/// pointed at the client's base URL.
///
/// Mirrors Go's `Factory` type in `a2aclient/factory.go`.
///
/// ## Example
///
/// ```swift
/// // Fetch the card and let the factory pick the best transport.
/// let card = try await AgentCardResolver(baseURL: agentURL).resolve()
/// let transport = A2ATransportFactory().transport(for: card, baseURL: agentURL)
/// let client = A2AClient(url: agentURL, transport: transport)
/// ```
public struct A2ATransportFactory: Sendable {

    // MARK: - Configuration

    /// An optional `URLSession` injected into created transports.
    ///
    /// Defaults to `URLSession.shared`. Primarily useful for testing.
    public let session: URLSession

    /// An optional static tenant string forwarded to ``TenantTransportDecorator``.
    ///
    /// When empty, the decorator reads ``TenantID/current`` from the task context.
    public let tenant: String

    // MARK: - Initialiser

    /// Creates an ``A2ATransportFactory``.
    ///
    /// - Parameters:
    ///   - session: `URLSession` used by every created transport.
    ///   - tenant:  Static tenant string to pre-configure on the
    ///              ``TenantTransportDecorator``.  Pass an empty string (the
    ///              default) to rely entirely on ``TenantID/current``.
    public init(session: URLSession = .shared, tenant: String = "") {
        self.session = session
        self.tenant = tenant
    }

    // MARK: - Factory method

    /// Selects an ``A2ATransport`` for the given ``AgentCard``.
    ///
    /// - Parameters:
    ///   - card:    The ``AgentCard`` describing the server's capabilities.
    ///   - baseURL: Fallback base URL used when no ``AgentInterface`` is found.
    /// - Returns: A transport (possibly wrapped in a ``TenantTransportDecorator``)
    ///            ready to use with ``A2AClient``.
    public func transport(for card: AgentCard, baseURL: String) -> any A2ATransport {
        let base = selectBaseTransport(from: card, fallbackURL: baseURL)
        return TenantTransportDecorator(base: base, tenant: tenant)
    }

    // MARK: - Internal selection

    /// Returns the raw (non-tenant-wrapped) transport chosen from the card.
    private func selectBaseTransport(
        from card: AgentCard,
        fallbackURL: String
    ) -> any A2ATransport {
        let candidates = card.supportedInterfaces
            .filter { isSupportedBinding($0.protocolBinding) }
            .sorted { lhs, rhs in
                // 1. Newer version wins.
                let lv = SemVer(lhs.protocolVersion)
                let rv = SemVer(rhs.protocolVersion)
                if lv != rv { return lv > rv }
                // 2. JSON-RPC preferred over REST.
                return bindingPreference(lhs.protocolBinding) < bindingPreference(rhs.protocolBinding)
            }

        guard let best = candidates.first else {
            // No supported interface found — fall back to default SseTransport.
            return SseTransport(url: fallbackURL, session: session)
        }

        let url = best.url.isEmpty ? fallbackURL : best.url

        switch best.protocolBinding {
        case A2AProtocolBinding.httpJSON:
            return RestTransport(url: url, session: session)
        default:
            // JSON_RPC (and any unknown binding we accepted) → SseTransport.
            return SseTransport(url: url, session: session)
        }
    }

    // MARK: - Helpers

    /// Returns `true` for bindings this factory knows how to handle.
    private func isSupportedBinding(_ binding: String) -> Bool {
        binding == A2AProtocolBinding.jsonRPC || binding == A2AProtocolBinding.httpJSON
    }

    /// Lower number = higher preference.
    private func bindingPreference(_ binding: String) -> Int {
        switch binding {
        case A2AProtocolBinding.jsonRPC:  return 0
        case A2AProtocolBinding.httpJSON: return 1
        default:                          return 2
        }
    }
}

// MARK: - SemVer (internal)

/// A minimal three-part semantic version used for transport selection.
///
/// Parses strings of the form `MAJOR.MINOR.PATCH` (extra components and
/// pre-release suffixes are ignored).  An empty or malformed string is treated
/// as `0.0.0`.
private struct SemVer: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ string: String) {
        let parts = string
            .split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
            .prefix(3)
            .map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        major = parts.count > 0 ? parts[0] : 0
        minor = parts.count > 1 ? parts[1] : 0
        patch = parts.count > 2 ? parts[2] : 0
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
