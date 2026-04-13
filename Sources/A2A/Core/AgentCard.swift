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

// MARK: - AgentCard

/// A self-describing manifest for an A2A agent.
///
/// The ``AgentCard`` provides essential metadata about an agent, including its
/// identity, capabilities, skills, supported communication methods, and
/// security requirements. It serves as a primary discovery mechanism for
/// clients to understand how to interact with the agent, typically served from
/// `/.well-known/agent-card.json`.
///
/// The ``supportedInterfaces`` list is ordered — the first entry is the
/// preferred interface. This replaces the older `url` + `preferredTransport`
/// + `additionalInterfaces` pattern.
///
/// Matches the proto3 `AgentCard` message in `specification/a2a.proto`.
public struct AgentCard: Codable, Sendable, Equatable {

    /// A human-readable name for the agent.
    public let name: String

    /// A concise, human-readable description of the agent's purpose and
    /// functionality.
    public let description: String

    /// Ordered list of supported interfaces. The first entry is preferred.
    public let supportedInterfaces: [AgentInterface]

    /// Information about the entity providing the agent service.
    public let provider: AgentProvider?

    /// The version string of the agent implementation itself.
    public let version: String

    /// An optional URL pointing to human-readable documentation for the agent.
    public let documentationUrl: String?

    /// A declaration of optional A2A protocol features and extensions
    /// supported by the agent.
    public let capabilities: AgentCapabilities

    /// A map of security schemes supported by the agent for authorization.
    public let securitySchemes: [String: SecurityScheme]?

    /// A list of security requirements that apply globally to all interactions.
    public let securityRequirements: [[String: [String]]]?

    /// Default set of supported input MIME types for all skills.
    public let defaultInputModes: [String]

    /// Default set of supported output MIME types for all skills.
    public let defaultOutputModes: [String]

    /// The set of skills (distinct functionalities) that the agent can perform.
    public let skills: [AgentSkill]

    /// JSON Web Signatures computed for this ``AgentCard``.
    public let signatures: [AgentCardSignature]?

    /// An optional URL to an icon for the agent.
    public let iconUrl: String?

    public init(
        name: String,
        description: String,
        supportedInterfaces: [AgentInterface],
        provider: AgentProvider? = nil,
        version: String,
        documentationUrl: String? = nil,
        capabilities: AgentCapabilities,
        securitySchemes: [String: SecurityScheme]? = nil,
        securityRequirements: [[String: [String]]]? = nil,
        defaultInputModes: [String],
        defaultOutputModes: [String],
        skills: [AgentSkill],
        signatures: [AgentCardSignature]? = nil,
        iconUrl: String? = nil
    ) {
        self.name = name
        self.description = description
        self.supportedInterfaces = supportedInterfaces
        self.provider = provider
        self.version = version
        self.documentationUrl = documentationUrl
        self.capabilities = capabilities
        self.securitySchemes = securitySchemes
        self.securityRequirements = securityRequirements
        self.defaultInputModes = defaultInputModes
        self.defaultOutputModes = defaultOutputModes
        self.skills = skills
        self.signatures = signatures
        self.iconUrl = iconUrl
    }

    // MARK: - Convenience accessors

    /// The URL of the preferred (first) interface.
    public var url: String? {
        supportedInterfaces.first?.url
    }

    /// The protocol binding of the preferred (first) interface.
    public var preferredProtocolBinding: String? {
        supportedInterfaces.first?.protocolBinding
    }
}

// MARK: - AgentCardSignature

/// Represents a JWS signature of an ``AgentCard``.
///
/// Follows the JSON format of RFC 7515 JSON Web Signature (JWS).
///
/// Matches the proto3 `AgentCardSignature` message in `specification/a2a.proto`.
public struct AgentCardSignature: Codable, Sendable, Equatable {

    /// The protected JWS header for the signature. Always a base64url-encoded
    /// JSON object.
    public let `protected`: String

    /// The computed signature, base64url-encoded.
    public let signature: String

    /// The unprotected JWS header values.
    public let header: JSONObject?

    public init(
        protected: String,
        signature: String,
        header: JSONObject? = nil
    ) {
        self.protected = protected
        self.signature = signature
        self.header = header
    }
}
