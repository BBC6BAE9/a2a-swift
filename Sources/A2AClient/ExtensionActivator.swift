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

// MARK: - Extension constants

/// The ``ServiceParams`` key used to propagate active extension URIs.
///
/// Handlers that need to signal which A2A extensions are enabled for a request
/// append extension URIs to this key in the outgoing ``ServiceParams``.
///
/// The transport layer translates these values into an `A2A-Extensions` HTTP
/// header on the wire.
///
/// Mirrors Go's `a2a.SvcParamExtensions = "A2A-Extensions"`.
public let SvcParamExtensions = "A2A-Extensions"

// MARK: - ExtensionActivator

/// A client-side ``A2AContextualHandler`` that selectively activates A2A
/// protocol extensions based on whether the target server supports them.
///
/// On each outgoing request, ``ExtensionActivator``:
/// 1. Inspects `request.card?.capabilities.extensions` for the server's
///    declared extensions.
/// 2. For each extension URI the activator was configured with, checks whether
///    the server supports it via ``isExtensionSupported(_:extensionURI:)``.
/// 3. Appends all supported extension URIs to the request's
///    ``SvcParamExtensions`` service param, which the transport converts to
///    the `A2A-Extensions` HTTP header.
///
/// If the server card is not yet available (e.g. first call before card fetch),
/// **all** configured extension URIs are appended — this mirrors the Go SDK
/// behaviour where a nil card is treated as "assume server supports everything".
///
/// Mirrors Go's `a2aext.NewActivator` in `a2aext/activator.go`.
///
/// ## Example
///
/// ```swift
/// let client = A2AClient(
///     url: "https://agent.example.com",
///     handlers: [
///         ExtensionActivator(extensionURIs:
///             "https://a2aprotocol.ai/extensions/thinking/v1",
///             "https://a2aprotocol.ai/extensions/code-interpreter/v1"
///         )
///     ]
/// )
/// ```
public final class ExtensionActivator: PassthroughContextualHandler, @unchecked Sendable {

    // MARK: - Properties

    private let extensionURIs: [String]

    // MARK: - Initialiser

    /// Creates an ``ExtensionActivator`` for the given extension URIs.
    ///
    /// - Parameter extensionURIs: The extension URIs to activate when supported
    ///   by the target server. Duplicates are preserved (the server card check
    ///   deduplicated by ``ServiceParams/append(_:_:)``).
    public init(extensionURIs: String...) {
        self.extensionURIs = extensionURIs
        super.init()
    }

    /// Creates an ``ExtensionActivator`` from an array of extension URIs.
    public init(extensionURIs: [String]) {
        self.extensionURIs = extensionURIs
        super.init()
    }

    // MARK: - A2AContextualHandler

    /// Appends each supported extension URI to the request's ``ServiceParams``.
    public override func handleRequest(_ request: A2ARequest) async throws -> [String: Any] {
        var rawRequest = request.rawRequest

        // Collect the URIs to activate for this request.
        let toActivate = extensionURIs.filter { uri in
            isExtensionSupported(request.card, extensionURI: uri)
        }

        guard !toActivate.isEmpty else {
            return rawRequest
        }

        // Merge into existing serviceParams (if any handler already set them).
        let existingDict = rawRequest[A2AHandlerPipeline.serviceParamsKey] as? [String: [String]] ?? [:]
        var params = ServiceParams(existingDict)
        params.append(SvcParamExtensions, toActivate)

        rawRequest[A2AHandlerPipeline.serviceParamsKey] = params.asDictionary()
        return rawRequest
    }
}

// MARK: - Extension support utilities

/// Returns `true` when `card` declares support for `extensionURI`.
///
/// When `card` is `nil` (server card not yet fetched), this function returns
/// `true` — assuming the server supports all configured extensions.
///
/// Mirrors Go's `isExtensionSupported` in `a2aext/utils.go`.
///
/// - Parameters:
///   - card: The server's ``AgentCard``, or `nil` if unavailable.
///   - extensionURI: The URI of the extension to check.
/// - Returns: `true` if the extension is declared, or if `card` is `nil`.
public func isExtensionSupported(_ card: AgentCard?, extensionURI: String) -> Bool {
    guard let card = card else {
        // Assume self-hosted server supports all extensions when card is unknown.
        return true
    }
    return card.capabilities.extensions.contains { $0.uri == extensionURI }
}
