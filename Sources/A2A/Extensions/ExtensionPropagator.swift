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

// MARK: - PropagatedRequestHeaders

/// Task-local storage for request headers extracted by a server-side propagator.
///
/// A server agent can read incoming A2A request headers that were propagated
/// by the client using ``ExtensionPropagator`` via ``PropagatedRequestHeaders``.
///
/// ## Example
///
/// ```swift
/// // In your AgentExecutor.execute(context:):
/// if let extensions = PropagatedRequestHeaders.current.get(SvcParamExtensions) {
///     // Client requested these extensions:  ["https://…/thinking/v1"]
/// }
/// ```
public struct PropagatedRequestHeaders: Sendable {
    /// Task-local storage for the current propagated headers.
    @TaskLocal public static var current = PropagatedRequestHeaders()

    /// The extracted headers.
    public var params: ServiceParams

    public init(params: ServiceParams = ServiceParams()) {
        self.params = params
    }

    /// Returns the values for a given header key (case-insensitive).
    public func get(_ key: String) -> [String]? {
        params.get(key)
    }
}

// MARK: - ExtensionPropagatorConfig

/// Configuration for an ``ExtensionPropagator``.
///
/// Controls which metadata and headers are propagated between client and server.
public struct ExtensionPropagatorConfig: Sendable {

    /// A predicate that decides whether a given metadata key should be
    /// propagated from the client to the server.
    ///
    /// Receives the key name and a reference to the ``AgentCard``.
    /// Defaults to propagating metadata whose key matches a server-supported
    /// extension URI.
    public var metadataPredicate: @Sendable (String, AgentCard?) -> Bool

    /// A predicate that decides whether a given incoming header key should be
    /// stored in ``PropagatedRequestHeaders/current`` on the server side.
    ///
    /// Receives the lower-cased header name.
    /// Defaults to keeping only the `a2a-extensions` header.
    public var serverHeaderPredicate: @Sendable (String) -> Bool

    /// Creates a default configuration.
    public init(
        metadataPredicate: (@Sendable (String, AgentCard?) -> Bool)? = nil,
        serverHeaderPredicate: (@Sendable (String) -> Bool)? = nil
    ) {
        self.metadataPredicate = metadataPredicate ?? { key, card in
            isExtensionSupported(card, extensionURI: key)
        }
        self.serverHeaderPredicate = serverHeaderPredicate ?? { key in
            key == SvcParamExtensions.lowercased()
        }
    }
}

// MARK: - ExtensionPropagator (client-side)

/// A client-side ``A2AContextualHandler`` that propagates context values —
/// such as active extension URIs — into outgoing request service params.
///
/// Works together with its server-side counterpart (configured via
/// ``ExtensionPropagatorConfig``) to carry metadata across the A2A wire.
///
/// Mirrors Go's `a2aext.NewClientPropagator` in `a2aext/propagator.go`.
///
/// ## Typical usage
///
/// ```swift
/// let client = A2AClient(
///     url: "https://agent.example.com",
///     handlers: [
///         ExtensionActivator(extensionURIs: "https://…/thinking/v1"),
///         ExtensionPropagator()
///     ]
/// )
/// ```
public final class ExtensionPropagator: PassthroughContextualHandler, @unchecked Sendable {

    // MARK: - Properties

    private let config: ExtensionPropagatorConfig

    // MARK: - Initialiser

    /// Creates an ``ExtensionPropagator`` with the given configuration.
    ///
    /// - Parameter config: Controls which metadata keys are propagated.
    ///   Defaults to propagating only extension URIs the server supports.
    public init(config: ExtensionPropagatorConfig = ExtensionPropagatorConfig()) {
        self.config = config
        super.init()
    }

    // MARK: - A2AContextualHandler

    /// Inspects the current task-local metadata and injects matching entries
    /// into the request's service params.
    ///
    /// The service params are embedded under
    /// ``A2AHandlerPipeline/serviceParamsKey`` so the pipeline can merge them
    /// before forwarding to the transport.
    public override func handleRequest(_ request: A2ARequest) async throws -> [String: Any] {
        var rawRequest = request.rawRequest

        // Read any headers already set in task-local propagated storage.
        let existing = PropagatedRequestHeaders.current.params

        // Use the predicate to decide which keys to forward.
        var toPropagate = ServiceParams()
        for (key, values) in existing.asDictionary() {
            if config.metadataPredicate(key, request.card) {
                toPropagate.append(key, values)
            }
        }

        if toPropagate.isEmpty { return rawRequest }

        // Merge with any serviceParams already set by previous handlers.
        let existingDict = rawRequest[A2AHandlerPipeline.serviceParamsKey] as? [String: [String]] ?? [:]
        var merged = ServiceParams(existingDict)
        for (key, values) in toPropagate.asDictionary() {
            merged.append(key, values)
        }

        rawRequest[A2AHandlerPipeline.serviceParamsKey] = merged.asDictionary()
        return rawRequest
    }
}

// MARK: - ServerExtensionPropagator

/// A server-side utility that extracts A2A extension headers from an incoming
/// ``ServiceParams`` and stores them in ``PropagatedRequestHeaders/current``.
///
/// Call ``extract(from:)`` at the entry point of your server request handler
/// (e.g. in the ``AgentExecutor`` before calling downstream clients) to make
/// the propagated headers available via ``PropagatedRequestHeaders/current``.
///
/// Mirrors Go's `a2aext.NewServerPropagator` in `a2aext/propagator.go`.
///
/// ## Example
///
/// ```swift
/// // In A2AServer or your AgentExecutor:
/// let propagated = ServerExtensionPropagator().extract(from: context.serviceParams)
/// await PropagatedRequestHeaders.$current.withValue(propagated) {
///     // PropagatedRequestHeaders.current is now populated
///     let result = try await executor.execute(context: context)
/// }
/// ```
public struct ServerExtensionPropagator: Sendable {

    private let config: ExtensionPropagatorConfig

    /// Creates a ``ServerExtensionPropagator`` with the given configuration.
    public init(config: ExtensionPropagatorConfig = ExtensionPropagatorConfig()) {
        self.config = config
    }

    /// Extracts matching headers from `params` and returns a
    /// ``PropagatedRequestHeaders`` value suitable for binding to
    /// ``PropagatedRequestHeaders/current``.
    ///
    /// - Parameter params: Incoming service params (e.g. from request headers).
    /// - Returns: Extracted headers filtered by ``ExtensionPropagatorConfig/serverHeaderPredicate``.
    public func extract(from params: ServiceParams) -> PropagatedRequestHeaders {
        var extracted = ServiceParams()
        for (key, values) in params.asDictionary() {
            if config.serverHeaderPredicate(key) {
                extracted.append(key, values)
            }
        }
        return PropagatedRequestHeaders(params: extracted)
    }
}
