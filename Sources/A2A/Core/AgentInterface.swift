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

// MARK: - AgentInterface

/// Declares a combination of a target URL, transport binding, and protocol
/// version for interacting with an agent.
///
/// Part of the ``AgentCard``, this allows an agent to expose the same
/// functionality over multiple protocol binding mechanisms (e.g. JSONRPC,
/// GRPC, HTTP+JSON).
///
/// The ``protocolBinding`` field is an open string so that future or custom
/// bindings can be declared without requiring a source change.
///
/// Matches the proto3 `AgentInterface` message in `specification/a2a.proto`.
public struct AgentInterface: Codable, Sendable, Equatable {

    /// The URL where this interface is available. Must be a valid absolute
    /// HTTPS URL in production.
    /// Example: `"https://api.example.com/a2a/v1"`
    public let url: String

    /// The protocol binding supported at this URL.
    ///
    /// Core values: `"JSONRPC"`, `"GRPC"`, `"HTTP+JSON"`. The field is an
    /// open string so that extended or custom bindings can be declared.
    public let protocolBinding: String

    /// Optional tenant ID to be used in the request path when calling the agent.
    public let tenant: String?

    /// The version of the A2A protocol this interface exposes.
    /// Use the latest supported minor version per major version.
    /// Examples: `"0.3"`, `"1.0"`
    public let protocolVersion: String

    public init(
        url: String,
        protocolBinding: String,
        tenant: String? = nil,
        protocolVersion: String
    ) {
        self.url = url
        self.protocolBinding = protocolBinding
        self.tenant = tenant
        self.protocolVersion = protocolVersion
    }
}
