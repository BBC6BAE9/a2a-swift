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

// MARK: - AuthCredential

/// An authentication credential value (e.g. a Bearer token or an API key).
///
/// Mirrors Go's `type AuthCredential string` in `a2aclient/auth.go`.
public typealias AuthCredential = String

// MARK: - CredentialsService

/// An interface for storing and retrieving per-session authentication credentials.
///
/// ``AuthHandler`` calls ``get(sessionID:scheme:)`` to look up the credential
/// for the active session before every request.
///
/// Mirrors Go's `CredentialsService` interface in `a2aclient/auth.go`.
public protocol CredentialsService: Sendable {

    /// Retrieves the credential for the given session and security scheme.
    ///
    /// - Parameters:
    ///   - sessionID: The identifier of the active session.
    ///   - scheme: The name of the security scheme (from the ``AgentCard``).
    /// - Returns: The stored ``AuthCredential``.
    /// - Throws: ``CredentialsServiceError/notFound`` if no credential exists for
    ///   the `(sessionID, scheme)` pair.
    func get(sessionID: SessionID, scheme: String) async throws -> AuthCredential
}

// MARK: - CredentialsServiceError

/// Errors that can be thrown by a ``CredentialsService``.
///
/// Mirrors Go's `ErrCredentialNotFound` in `a2aclient/auth.go`.
public enum CredentialsServiceError: Error, Equatable {

    /// No credential is stored for the given (sessionID, scheme) pair.
    case notFound

    /// An unexpected error occurred during credential lookup.
    case custom(String)
}

// MARK: - InMemoryCredentialsStore

/// A thread-safe, in-memory implementation of ``CredentialsService``.
///
/// Credentials are organised as a nested map:
/// `SessionID → (scheme name → AuthCredential)`.
/// Use ``set(_:scheme:credential:)`` to populate the store before making
/// A2A calls.
///
/// Mirrors Go's `InMemoryCredentialsStore` in `a2aclient/auth.go`.
///
/// ## Example
///
/// ```swift
/// let store = InMemoryCredentialsStore()
/// store.set("session-1", scheme: "bearerAuth", credential: "my-token")
///
/// let handler = AuthHandler(credentialsService: store)
/// let client = A2AClient(url: "http://localhost:8000", handlers: [handler])
///
/// await SessionID.$current.withValue("session-1") {
///     let response = try await client.messageSend(myMessage)
///     // Authorization: Bearer my-token is injected automatically.
/// }
/// ```
public final class InMemoryCredentialsStore: CredentialsService, @unchecked Sendable {

    // MARK: - Types

    /// Credentials keyed by security scheme name.
    private typealias SessionCredentials = [String: AuthCredential]

    // MARK: - Storage

    private let lock = NSLock()
    private var credentials: [SessionID: SessionCredentials] = [:]

    // MARK: - Init

    public init() {}

    // MARK: - CredentialsService

    /// Retrieves the credential for the given session and security scheme.
    ///
    /// - Throws: ``CredentialsServiceError/notFound`` if the credential is absent.
    public func get(sessionID: SessionID, scheme: String) async throws -> AuthCredential {
        let result = lock.withLock { credentials[sessionID]?[scheme] }
        guard let credential = result else {
            throw CredentialsServiceError.notFound
        }
        return credential
    }

    // MARK: - Mutation

    /// Stores a credential for the given session and security scheme.
    ///
    /// If a credential already exists for this `(sessionID, scheme)` pair it is
    /// overwritten.
    ///
    /// - Parameters:
    ///   - sessionID: The session identifier.
    ///   - scheme: The security scheme name (must match the name in the ``AgentCard``).
    ///   - credential: The credential value (e.g. a Bearer token or API key).
    public func set(_ sessionID: SessionID, scheme: String, credential: AuthCredential) {
        lock.withLock {
            if credentials[sessionID] == nil {
                credentials[sessionID] = [:]
            }
            credentials[sessionID]![scheme] = credential
        }
    }

    /// Removes all credentials for a given session.
    ///
    /// - Parameter sessionID: The session whose credentials should be purged.
    public func remove(_ sessionID: SessionID) {
        lock.withLock { _ = credentials.removeValue(forKey: sessionID) }
    }
}
