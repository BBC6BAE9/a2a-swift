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
import SwiftProtobuf

// MARK: - V0AgentCardParser
//
// Parses a raw JSON dictionary that may contain either a v0.3 or v1.0 AgentCard
// and returns a normalised v1.0 ``AgentCard``.
//
// Mirrors Go's `NewAgentCardParser()` / `agentCardCompat` logic in
// `a2acompat/a2av0/agentcard.go`.

/// Parses an ``AgentCard`` from a raw JSON dictionary that may be in either
/// v0.3 or v1.0 format.
///
/// **Selection logic:**
/// 1. If the JSON contains a `supportedInterfaces` field (v1.0), hand the raw
///    JSON directly to the SwiftProtobuf JSON decoder — it is already v1.0.
/// 2. Otherwise, interpret the JSON as v0.3 (`url`, `preferredTransport`,
///    `additionalInterfaces`) and synthesise a v1.0 ``AgentCard``.
///
/// - Parameter dict: The JSON object received from the server (already parsed
///   by `JSONSerialization`).
/// - Returns: A normalised v1.0 ``AgentCard``.
/// - Throws: ``A2ATransportError/parsing(message:)`` if the JSON cannot be
///   decoded.
func parseV0AgentCard(from dict: [String: Any]) throws -> AgentCard {
    // Fast path: if the card already has v1.0 `supportedInterfaces`, let
    // SwiftProtobuf decode the raw JSON — field names are the same.
    if let interfaces = dict["supportedInterfaces"] as? [[String: Any]],
       !interfaces.isEmpty {
        let jsonData = try jsonData(from: dict)
        return try decodeCard(jsonData)
    }

    // Slow path: parse v0.3 compat JSON and build a v1.0 AgentCard manually.
    let jsonData = try jsonData(from: dict)
    let compat: V0AgentCardCompat
    do {
        compat = try JSONDecoder().decode(V0AgentCardCompat.self, from: jsonData)
    } catch {
        // Fall back: try direct SwiftProtobuf decoding in case the JSON was
        // actually v1.0 but without `supportedInterfaces`.
        return try decodeCard(jsonData)
    }

    return buildV1Card(from: compat)
}

// MARK: - Internal helpers

private func jsonData(from dict: [String: Any]) throws -> Data {
    do {
        return try JSONSerialization.data(withJSONObject: dict)
    } catch {
        throw A2ATransportError.parsing(
            message: "Failed to serialise AgentCard JSON: \(error.localizedDescription)"
        )
    }
}

private func decodeCard(_ data: Data) throws -> AgentCard {
    do {
        return try AgentCard(jsonUTF8Data: data)
    } catch {
        throw A2ATransportError.parsing(
            message: "Failed to decode AgentCard: \(error.localizedDescription)"
        )
    }
}

/// Builds a v1.0 ``AgentCard`` from a v0.3 ``V0AgentCardCompat`` struct.
private func buildV1Card(from compat: V0AgentCardCompat) -> AgentCard {
    var card = AgentCard()

    card.name = compat.name ?? ""
    card.description_p = compat.description ?? ""
    card.version = compat.version ?? ""
    if let docURL = compat.documentationUrl { card.documentationURL = docURL }

    // Build supported interfaces from v0.3 flat fields.
    card.supportedInterfaces = buildInterfaces(from: compat)

    // Capabilities.
    if let caps = compat.capabilities {
        var agentCaps = AgentCapabilities()
        if let s = caps.streaming { agentCaps.streaming = s }
        if let p = caps.pushNotifications { agentCaps.pushNotifications = p }
        // v0.3 `supportsAuthenticatedExtendedCard` → v1.0 `extendedAgentCard`
        if let ext = compat.supportsAuthenticatedExtendedCard { agentCaps.extendedAgentCard = ext }
        card.capabilities = agentCaps
    } else if let ext = compat.supportsAuthenticatedExtendedCard {
        var agentCaps = AgentCapabilities()
        agentCaps.extendedAgentCard = ext
        card.capabilities = agentCaps
    }

    // Input / output modes.
    if let modes = compat.defaultInputModes { card.defaultInputModes = modes }
    if let modes = compat.defaultOutputModes { card.defaultOutputModes = modes }

    // Skills.
    if let skills = compat.skills {
        card.skills = skills.map { buildV1Skill(from: $0) }
    }

    return card
}

/// Converts v0.3 URL/transport fields to a list of v1.0 ``AgentInterface``s.
private func buildInterfaces(from compat: V0AgentCardCompat) -> [AgentInterface] {
    var interfaces: [AgentInterface] = []

    // Primary URL.
    if let url = compat.url, !url.isEmpty {
        var iface = AgentInterface()
        iface.url = url
        iface.protocolBinding = bindingFor(transport: compat.preferredTransport)
        iface.protocolVersion = compat.protocolVersion ?? "0.3"
        interfaces.append(iface)
    }

    // Additional interfaces.
    if let additional = compat.additionalInterfaces {
        for ai in additional {
            var iface = AgentInterface()
            iface.url = ai.url
            iface.protocolBinding = bindingFor(transport: ai.transport)
            iface.protocolVersion = compat.protocolVersion ?? "0.3"
            interfaces.append(iface)
        }
    }

    return interfaces
}

/// Maps a v0.3 transport string to a v1.0 protocol binding constant.
private func bindingFor(transport: String?) -> String {
    switch transport?.uppercased() {
    case "JSONRPC", "JSON_RPC", nil:
        return A2AProtocolBinding.jsonRPC
    case "REST", "HTTP_JSON":
        return A2AProtocolBinding.httpJSON
    default:
        return A2AProtocolBinding.jsonRPC
    }
}

/// Converts a v0.3 ``V0AgentSkill`` to a v1.0 ``AgentSkill``.
private func buildV1Skill(from v0Skill: V0AgentSkill) -> AgentSkill {
    var skill = AgentSkill()
    skill.id = v0Skill.id
    skill.name = v0Skill.name
    if let desc = v0Skill.description { skill.description_p = desc }
    if let tags = v0Skill.tags { skill.tags = tags }
    if let examples = v0Skill.examples { skill.examples = examples }
    if let inputModes = v0Skill.inputModes { skill.inputModes = inputModes }
    if let outputModes = v0Skill.outputModes { skill.outputModes = outputModes }
    return skill
}
