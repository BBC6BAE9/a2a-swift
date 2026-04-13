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

// MARK: - Part

/// Represents a container for a section of communication content.
///
/// Parts can be purely textual, a file (image, video, etc.) or a structured
/// data blob (e.g. JSON). The content is a discriminated union with four cases:
/// `text`, `raw` (base64-encoded bytes), `url` (URI to file content), or `data`
/// (arbitrary JSON value). Top-level `filename` and `mediaType` fields apply to
/// any part type.
///
/// Matches the proto3 `Part` message in `specification/a2a.proto`.
public enum Part: Codable, Sendable, Equatable {

    /// A plain text content part.
    case text(
        text: String,
        filename: String? = nil,
        mediaType: String? = nil,
        metadata: JSONObject? = nil
    )

    /// A raw binary content part. The payload is base64-encoded in JSON.
    case raw(
        raw: Data,
        filename: String? = nil,
        mediaType: String? = nil,
        metadata: JSONObject? = nil
    )

    /// A URL pointing to the file's content.
    case url(
        url: String,
        filename: String? = nil,
        mediaType: String? = nil,
        metadata: JSONObject? = nil
    )

    /// Arbitrary structured JSON data (object, array, string, number, bool, or null).
    case data(
        data: AnyCodable,
        filename: String? = nil,
        mediaType: String? = nil,
        metadata: JSONObject? = nil
    )

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case raw
        case url
        case data
        case filename
        case mediaType
        case metadata
    }

    // MARK: - Decodable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let filename = try container.decodeIfPresent(String.self, forKey: .filename)
        let mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        let metadata = try container.decodeIfPresent(JSONObject.self, forKey: .metadata)

        switch kind {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text: text, filename: filename, mediaType: mediaType, metadata: metadata)

        case "raw":
            let raw = try container.decode(Data.self, forKey: .raw)
            self = .raw(raw: raw, filename: filename, mediaType: mediaType, metadata: metadata)

        case "url":
            let url = try container.decode(String.self, forKey: .url)
            self = .url(url: url, filename: filename, mediaType: mediaType, metadata: metadata)

        case "data":
            let data = try container.decode(AnyCodable.self, forKey: .data)
            self = .data(data: data, filename: filename, mediaType: mediaType, metadata: metadata)

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown Part kind: \(kind)"
            )
        }
    }

    // MARK: - Encodable

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text, let filename, let mediaType, let metadata):
            try container.encode("text", forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(filename, forKey: .filename)
            try container.encodeIfPresent(mediaType, forKey: .mediaType)
            try container.encodeIfPresent(metadata, forKey: .metadata)

        case .raw(let raw, let filename, let mediaType, let metadata):
            try container.encode("raw", forKey: .kind)
            try container.encode(raw, forKey: .raw)
            try container.encodeIfPresent(filename, forKey: .filename)
            try container.encodeIfPresent(mediaType, forKey: .mediaType)
            try container.encodeIfPresent(metadata, forKey: .metadata)

        case .url(let url, let filename, let mediaType, let metadata):
            try container.encode("url", forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(filename, forKey: .filename)
            try container.encodeIfPresent(mediaType, forKey: .mediaType)
            try container.encodeIfPresent(metadata, forKey: .metadata)

        case .data(let data, let filename, let mediaType, let metadata):
            try container.encode("data", forKey: .kind)
            try container.encode(data, forKey: .data)
            try container.encodeIfPresent(filename, forKey: .filename)
            try container.encodeIfPresent(mediaType, forKey: .mediaType)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        }
    }
}
