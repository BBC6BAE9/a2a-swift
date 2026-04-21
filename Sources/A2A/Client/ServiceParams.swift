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

// MARK: - ServiceParams

/// A case-insensitive multi-value string map for horizontally applicable
/// request parameters (e.g. HTTP headers, metadata).
///
/// Keys are always stored in lower-case. Values are deduplicated when
/// appended via ``append(_:_:)``.
///
/// Mirrors Go's `a2aclient.ServiceParams` in `a2aclient/middleware.go`.
///
/// ## Example
///
/// ```swift
/// var params = ServiceParams()
/// params.append("Authorization", "Bearer token")
/// params.append("X-A2A-Extensions", "ext-a", "ext-b")
///
/// let auth = params.get("authorization")  // ["Bearer token"]
/// let headers = params.asHTTPHeaders()    // ["authorization": "Bearer token", …]
/// ```
public struct ServiceParams: Sendable {

    // MARK: - Internal storage

    /// Internal storage: lower-cased keys → ordered list of values.
    private var storage: [String: [String]]

    // MARK: - Initialisers

    /// Creates an empty ``ServiceParams``.
    public init() {
        self.storage = [:]
    }

    /// Creates a ``ServiceParams`` from a flat `[String: String]` dictionary.
    ///
    /// Each key-value pair becomes a single-element list entry.
    /// Keys are lower-cased during import.
    public init(_ dict: [String: String]) {
        self.storage = Dictionary(uniqueKeysWithValues: dict.map { k, v in
            (k.lowercased(), [v])
        })
    }

    /// Creates a ``ServiceParams`` from a `[String: [String]]` dictionary.
    ///
    /// Keys are lower-cased during import.
    public init(_ dict: [String: [String]]) {
        self.storage = Dictionary(uniqueKeysWithValues: dict.map { k, v in
            (k.lowercased(), v)
        })
    }

    // MARK: - Access

    /// Returns the values for `key`, performing a case-insensitive lookup.
    ///
    /// Returns `nil` when the key is absent (or has an empty value list).
    ///
    /// Mirrors Go's `ServiceParams.Get(key)`.
    public func get(_ key: String) -> [String]? {
        let values = storage[key.lowercased()]
        return values?.isEmpty == false ? values : nil
    }

    /// Returns `true` if the map contains no entries.
    public var isEmpty: Bool { storage.isEmpty }

    // MARK: - Mutation

    /// Appends `vals` to the list associated with `key`, skipping duplicates.
    ///
    /// The key is stored in lower-case. Existing values are preserved.
    ///
    /// Mirrors Go's `ServiceParams.Append(key, vals…)`.
    public mutating func append(_ key: String, _ vals: String...) {
        append(key, vals)
    }

    /// Appends a collection of values to the list associated with `key`.
    public mutating func append(_ key: String, _ vals: [String]) {
        let k = key.lowercased()
        var current = storage[k] ?? []
        for v in vals where !current.contains(v) {
            current.append(v)
        }
        storage[k] = current
    }

    // MARK: - Conversion

    /// Returns the internal storage as `[String: [String]]` with lower-cased keys.
    ///
    /// Suitable for passing to underlying transports that accept multi-value headers.
    public func asDictionary() -> [String: [String]] {
        storage
    }

    /// Flattens multi-value entries into a `[String: String]` dictionary,
    /// joining multiple values with `", "`.
    ///
    /// Suitable for setting HTTP headers where a single string value is expected.
    public func asHTTPHeaders() -> [String: String] {
        storage.compactMapValues { values -> String? in
            guard !values.isEmpty else { return nil }
            return values.joined(separator: ", ")
        }
    }

    // MARK: - Internal clone helper

    func clone() -> ServiceParams {
        var copy = ServiceParams()
        copy.storage = storage.mapValues { $0 }
        return copy
    }
}

// MARK: - Equatable & CustomStringConvertible

extension ServiceParams: Equatable {
    public static func == (lhs: ServiceParams, rhs: ServiceParams) -> Bool {
        lhs.storage == rhs.storage
    }
}

extension ServiceParams: CustomStringConvertible {
    public var description: String {
        storage.description
    }
}
