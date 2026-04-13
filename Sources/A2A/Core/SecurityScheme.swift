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

// MARK: - SecurityScheme

/// Defines a security scheme used to protect an agent's API endpoints.
///
/// This is a discriminated union based on the `type` field, following the
/// OpenAPI 3.2 Security Scheme Object structure.
///
/// Matches the proto3 `SecurityScheme` oneof in `specification/a2a.proto`.
public enum SecurityScheme: Codable, Sendable, Equatable {

    /// API key-based security scheme.
    case apiKey(description: String? = nil, name: String, in: String)

    /// HTTP authentication scheme (e.g., Basic, Bearer).
    case http(description: String? = nil, scheme: String, bearerFormat: String? = nil)

    /// OAuth 2.0 security scheme.
    case oauth2(description: String? = nil, flows: OAuthFlows, oauth2MetadataUrl: String? = nil)

    /// OpenID Connect security scheme.
    case openIdConnect(description: String? = nil, openIdConnectUrl: String)

    /// Mutual TLS authentication scheme.
    case mutualTls(description: String? = nil)

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case type
        case description
        case name
        case `in`
        case scheme
        case bearerFormat
        case flows
        case oauth2MetadataUrl
        case openIdConnectUrl
    }

    // MARK: - Decodable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "apiKey":
            let description = try container.decodeIfPresent(String.self, forKey: .description)
            let name = try container.decode(String.self, forKey: .name)
            let inValue = try container.decode(String.self, forKey: .in)
            self = .apiKey(description: description, name: name, in: inValue)

        case "http":
            let description = try container.decodeIfPresent(String.self, forKey: .description)
            let scheme = try container.decode(String.self, forKey: .scheme)
            let bearerFormat = try container.decodeIfPresent(String.self, forKey: .bearerFormat)
            self = .http(description: description, scheme: scheme, bearerFormat: bearerFormat)

        case "oauth2":
            let description = try container.decodeIfPresent(String.self, forKey: .description)
            let flows = try container.decode(OAuthFlows.self, forKey: .flows)
            let metadataUrl = try container.decodeIfPresent(String.self, forKey: .oauth2MetadataUrl)
            self = .oauth2(description: description, flows: flows, oauth2MetadataUrl: metadataUrl)

        case "openIdConnect":
            let description = try container.decodeIfPresent(String.self, forKey: .description)
            let url = try container.decode(String.self, forKey: .openIdConnectUrl)
            self = .openIdConnect(description: description, openIdConnectUrl: url)

        case "mutualTls":
            let description = try container.decodeIfPresent(String.self, forKey: .description)
            self = .mutualTls(description: description)

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown SecurityScheme type: \(type)"
            )
        }
    }

    // MARK: - Encodable

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .apiKey(let description, let name, let inValue):
            try container.encode("apiKey", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encode(name, forKey: .name)
            try container.encode(inValue, forKey: .in)

        case .http(let description, let scheme, let bearerFormat):
            try container.encode("http", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encode(scheme, forKey: .scheme)
            try container.encodeIfPresent(bearerFormat, forKey: .bearerFormat)

        case .oauth2(let description, let flows, let metadataUrl):
            try container.encode("oauth2", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encode(flows, forKey: .flows)
            try container.encodeIfPresent(metadataUrl, forKey: .oauth2MetadataUrl)

        case .openIdConnect(let description, let url):
            try container.encode("openIdConnect", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encode(url, forKey: .openIdConnectUrl)

        case .mutualTls(let description):
            try container.encode("mutualTls", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
        }
    }
}

// MARK: - OAuthFlows

/// A mutually-exclusive (oneof) container for the OAuth 2.0 flow configuration.
///
/// Matches the proto3 `OAuthFlows` oneof in `specification/a2a.proto`.
/// The flow kind is encoded / decoded via the `type` key.
public enum OAuthFlows: Codable, Sendable, Equatable {

    /// Configuration for the OAuth 2.0 Authorization Code flow (with optional PKCE).
    case authorizationCode(AuthorizationCodeOAuthFlow)

    /// Configuration for the OAuth 2.0 Client Credentials flow.
    case clientCredentials(ClientCredentialsOAuthFlow)

    /// Configuration for the OAuth 2.0 Device Code flow (RFC 8628).
    case deviceCode(DeviceCodeOAuthFlow)

    /// Configuration for the OAuth 2.0 Implicit flow.
    /// - Note: Deprecated — prefer Authorization Code + PKCE.
    case implicit(ImplicitOAuthFlow)

    /// Configuration for the OAuth 2.0 Resource Owner Password Credentials flow.
    /// - Note: Deprecated — prefer Authorization Code + PKCE or Device Code.
    case password(PasswordOAuthFlow)

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case type
        case authorizationUrl
        case tokenUrl
        case refreshUrl
        case scopes
        case pkceRequired
        case deviceAuthorizationUrl
    }

    // MARK: - Decodable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "authorizationCode":
            self = .authorizationCode(try AuthorizationCodeOAuthFlow(from: decoder))
        case "clientCredentials":
            self = .clientCredentials(try ClientCredentialsOAuthFlow(from: decoder))
        case "deviceCode":
            self = .deviceCode(try DeviceCodeOAuthFlow(from: decoder))
        case "implicit":
            self = .implicit(try ImplicitOAuthFlow(from: decoder))
        case "password":
            self = .password(try PasswordOAuthFlow(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown OAuthFlows type: \(type)"
            )
        }
    }

    // MARK: - Encodable

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .authorizationCode(let flow):
            try container.encode("authorizationCode", forKey: .type)
            try flow.encode(to: encoder)
        case .clientCredentials(let flow):
            try container.encode("clientCredentials", forKey: .type)
            try flow.encode(to: encoder)
        case .deviceCode(let flow):
            try container.encode("deviceCode", forKey: .type)
            try flow.encode(to: encoder)
        case .implicit(let flow):
            try container.encode("implicit", forKey: .type)
            try flow.encode(to: encoder)
        case .password(let flow):
            try container.encode("password", forKey: .type)
            try flow.encode(to: encoder)
        }
    }
}

// MARK: - AuthorizationCodeOAuthFlow

/// Configuration for the OAuth 2.0 Authorization Code flow.
///
/// Matches the proto3 `AuthorizationCodeOAuthFlow` message in
/// `specification/a2a.proto`.
public struct AuthorizationCodeOAuthFlow: Codable, Sendable, Equatable {

    /// The authorization URL for this flow.
    public let authorizationUrl: String

    /// The token URL for this flow.
    public let tokenUrl: String

    /// The URL for obtaining refresh tokens.
    public let refreshUrl: String?

    /// The available scopes. Keys are scope names, values are descriptions.
    public let scopes: [String: String]

    /// Whether PKCE (RFC 7636) is required. Recommended for all clients.
    public let pkceRequired: Bool

    public init(
        authorizationUrl: String,
        tokenUrl: String,
        refreshUrl: String? = nil,
        scopes: [String: String],
        pkceRequired: Bool = false
    ) {
        self.authorizationUrl = authorizationUrl
        self.tokenUrl = tokenUrl
        self.refreshUrl = refreshUrl
        self.scopes = scopes
        self.pkceRequired = pkceRequired
    }
}

// MARK: - ClientCredentialsOAuthFlow

/// Configuration for the OAuth 2.0 Client Credentials flow.
///
/// Matches the proto3 `ClientCredentialsOAuthFlow` message in
/// `specification/a2a.proto`.
public struct ClientCredentialsOAuthFlow: Codable, Sendable, Equatable {

    /// The token URL for this flow.
    public let tokenUrl: String

    /// The URL for obtaining refresh tokens.
    public let refreshUrl: String?

    /// The available scopes. Keys are scope names, values are descriptions.
    public let scopes: [String: String]

    public init(tokenUrl: String, refreshUrl: String? = nil, scopes: [String: String]) {
        self.tokenUrl = tokenUrl
        self.refreshUrl = refreshUrl
        self.scopes = scopes
    }
}

// MARK: - DeviceCodeOAuthFlow

/// Configuration for the OAuth 2.0 Device Code flow (RFC 8628).
///
/// Designed for input-constrained devices (IoT, CLI tools) where the user
/// authenticates on a separate device.
///
/// Matches the proto3 `DeviceCodeOAuthFlow` message in
/// `specification/a2a.proto`.
public struct DeviceCodeOAuthFlow: Codable, Sendable, Equatable {

    /// The device authorization endpoint URL.
    public let deviceAuthorizationUrl: String

    /// The token URL for this flow.
    public let tokenUrl: String

    /// The URL for obtaining refresh tokens.
    public let refreshUrl: String?

    /// The available scopes. Keys are scope names, values are descriptions.
    public let scopes: [String: String]

    public init(
        deviceAuthorizationUrl: String,
        tokenUrl: String,
        refreshUrl: String? = nil,
        scopes: [String: String]
    ) {
        self.deviceAuthorizationUrl = deviceAuthorizationUrl
        self.tokenUrl = tokenUrl
        self.refreshUrl = refreshUrl
        self.scopes = scopes
    }
}

// MARK: - ImplicitOAuthFlow

/// Configuration for the OAuth 2.0 Implicit flow.
///
/// - Note: Deprecated — prefer Authorization Code + PKCE.
///
/// Matches the proto3 `ImplicitOAuthFlow` message in `specification/a2a.proto`.
public struct ImplicitOAuthFlow: Codable, Sendable, Equatable {

    /// The authorization URL for this flow.
    public let authorizationUrl: String?

    /// The URL for obtaining refresh tokens.
    public let refreshUrl: String?

    /// The available scopes. Keys are scope names, values are descriptions.
    public let scopes: [String: String]

    public init(
        authorizationUrl: String? = nil,
        refreshUrl: String? = nil,
        scopes: [String: String]
    ) {
        self.authorizationUrl = authorizationUrl
        self.refreshUrl = refreshUrl
        self.scopes = scopes
    }
}

// MARK: - PasswordOAuthFlow

/// Configuration for the OAuth 2.0 Resource Owner Password Credentials flow.
///
/// - Note: Deprecated — prefer Authorization Code + PKCE or Device Code.
///
/// Matches the proto3 `PasswordOAuthFlow` message in `specification/a2a.proto`.
public struct PasswordOAuthFlow: Codable, Sendable, Equatable {

    /// The token URL for this flow.
    public let tokenUrl: String?

    /// The URL for obtaining refresh tokens.
    public let refreshUrl: String?

    /// The available scopes. Keys are scope names, values are descriptions.
    public let scopes: [String: String]

    public init(
        tokenUrl: String? = nil,
        refreshUrl: String? = nil,
        scopes: [String: String]
    ) {
        self.tokenUrl = tokenUrl
        self.refreshUrl = refreshUrl
        self.scopes = scopes
    }
}
