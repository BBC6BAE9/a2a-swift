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
#if canImport(os)
import os
#endif

// MARK: - AuthHandler

/// An ``A2AContextualHandler`` that automatically injects authentication credentials
/// into outgoing requests based on the active ``SessionID`` and the server's
/// ``AgentCard`` security configuration.
///
/// For every outgoing request, ``AuthHandler``:
/// 1. Reads the current ``SessionID`` from `@TaskLocal` storage.
/// 2. Iterates the ``AgentCard``'s `securityRequirements` and `securitySchemes`.
/// 3. Calls ``CredentialsService/get(sessionID:scheme:)`` for each scheme.
/// 4. On the first match, injects the appropriate header:
///    - **HTTP / OAuth2** schemes: `Authorization: Bearer <credential>`
///    - **API key** schemes: `<scheme.name>: <credential>` (header location only)
///
/// The handler signals the injected params by embedding a
/// ``A2AHandlerPipeline/serviceParamsKey`` entry in the returned request dict,
/// which the pipeline merges and forwards to the transport.
///
/// Mirrors Go's `AuthInterceptor` in `a2aclient/auth.go`.
///
/// ## Example
///
/// ```swift
/// let store = InMemoryCredentialsStore()
/// store.set("session-1", scheme: "bearerAuth", credential: "my-token")
///
/// let client = A2AClient(
///     url: "http://localhost:8000",
///     handlers: [AuthHandler(credentialsService: store)]
/// )
///
/// // Attach the session ID to the current task and make the call.
/// await SessionID.$current.withValue("session-1") {
///     let card = try await client.getAgentCard()   // also updates internal card
///     let response = try await client.messageSend(myMessage)
///     // → Authorization: Bearer my-token is injected automatically.
/// }
/// ```
public final class AuthHandler: PassthroughContextualHandler, @unchecked Sendable {

    // MARK: - Properties

    private let service: any CredentialsService

    #if canImport(os)
    private let logger = Logger(subsystem: "A2UIV09_A2A", category: "AuthHandler")
    #endif

    // MARK: - Init

    /// Creates an ``AuthHandler`` backed by the given ``CredentialsService``.
    ///
    /// - Parameter credentialsService: The service used to look up credentials
    ///   by session ID and security scheme name.
    public init(credentialsService: any CredentialsService) {
        self.service = credentialsService
    }

    // MARK: - A2AContextualHandler

    /// Inspects the request context and injects auth headers when a matching
    /// credential is found for the active ``SessionID``.
    public override func handleRequest(_ request: A2ARequest) async throws -> [String: Any] {
        var rawRequest = request.rawRequest

        // Guard: skip if no card or no security config.
        guard
            let card = request.card,
            !card.securityRequirements.isEmpty,
            !card.securitySchemes.isEmpty
        else {
            return rawRequest
        }

        // Guard: skip if no session ID is attached to the current task.
        guard let sessionID = SessionID.current else {
            return rawRequest
        }

        // Iterate security requirements in order; first successful credential wins.
        for requirement in card.securityRequirements {
            for schemeName in requirement.schemes.keys {
                // Try to retrieve the credential for this (session, scheme) pair.
                let credential: AuthCredential
                do {
                    credential = try await service.get(sessionID: sessionID, scheme: schemeName)
                } catch CredentialsServiceError.notFound {
                    continue
                } catch {
                    #if canImport(os)
                    logger.error("CredentialsService error for scheme '\(schemeName)': \(error.localizedDescription)")
                    #endif
                    continue
                }

                // Retrieve the scheme definition from the card.
                guard let scheme = card.securitySchemes[schemeName] else { continue }

                // Build the service params for this credential.
                var authParams = ServiceParams()
                switch scheme.scheme {
                case .httpAuthSecurityScheme, .oauth2SecurityScheme, .openIDConnectSecurityScheme:
                    // Bearer token in the Authorization header.
                    authParams.append("Authorization", "Bearer \(credential)")
                case .apiKeySecurityScheme(let apiKey):
                    // API key injected into the header named by the scheme.
                    // Only "header" location is supported here; query/cookie are not HTTP headers.
                    if apiKey.location.lowercased() == "header" || apiKey.location.isEmpty {
                        authParams.append(apiKey.name, credential)
                    }
                case .mtlsSecurityScheme:
                    // mTLS is handled at the transport layer; no header injection needed.
                    break
                case nil:
                    break
                }

                // Embed the serviceParams in the returned dict using the pipeline sentinel key.
                if !authParams.isEmpty {
                    rawRequest[A2AHandlerPipeline.serviceParamsKey] = authParams.asDictionary()
                }
                return rawRequest
            }
        }

        // No matching credential found; return request unmodified.
        return rawRequest
    }
}
