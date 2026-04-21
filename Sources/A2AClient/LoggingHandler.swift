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

// MARK: - LoggingConfig

/// Controls the behavior of ``LoggingHandler``.
///
/// Mirrors Go's `LoggingConfig` in `a2aclient/logging.go`.
public struct LoggingConfig: Sendable {

    /// The log level used for successful requests and responses.
    ///
    /// On Apple platforms this maps to `OSLogType`. On Linux it controls
    /// whether the message is printed to stdout.
    /// Default: `.default` (informational).
    public var level: LogLevel

    /// The log level used when a request fails (i.e. the response contains an error).
    ///
    /// Default: `.error`.
    public var errorLevel: LogLevel

    /// When `true`, the full request and response payloads are included in log
    /// output. When `false` (default), only the method name and timing are logged.
    ///
    /// Mirrors Go's `LoggingConfig.LogPayload`.
    public var logPayload: Bool

    /// Creates a ``LoggingConfig``.
    public init(
        level: LogLevel = .default,
        errorLevel: LogLevel = .error,
        logPayload: Bool = false
    ) {
        self.level = level
        self.errorLevel = errorLevel
        self.logPayload = logPayload
    }

    // MARK: - LogLevel

    /// Abstraction over platform log levels.
    public enum LogLevel: Sendable {
        /// Verbose / debug messages.
        case debug
        /// Standard informational messages.
        case `default`
        /// Warning-level messages.
        case warning
        /// Error-level messages.
        case error

        #if canImport(os)
        var osLogType: OSLogType {
            switch self {
            case .debug:   return .debug
            case .default: return .default
            case .warning: return .default   // OSLog has no distinct "warning"
            case .error:   return .error
            }
        }
        #endif
    }
}

// MARK: - LoggingHandler

/// An ``A2AHandler`` that logs outgoing A2A requests and incoming responses.
///
/// Insert it into the handler list when creating an ``A2AClient`` to get
/// automatic structured logging for every JSON-RPC call:
///
/// ```swift
/// let loggingHandler = LoggingHandler(config: LoggingConfig(logPayload: true))
/// let client = A2AClient(url: "http://agent.com", handlers: [loggingHandler])
/// ```
///
/// Each call logs:
/// - **Before**: method name, request ID (and optionally the full params dict).
/// - **After**: method name, request ID, duration (and optionally the result dict,
///   or the error if one was returned).
///
/// Mirrors Go's `NewLoggingInterceptor` / `loggingInterceptor` in
/// `a2aclient/logging.go`.
public final class LoggingHandler: PassthroughHandler, @unchecked Sendable {

    // MARK: - Properties

    private let config: LoggingConfig

    /// Tracks the start time for each in-flight request, keyed by JSON-RPC `id`.
    /// Protected by a lock for thread safety.
    private let lock = NSLock()
    private var _startTimes: [Int: Date] = [:]

    #if canImport(os)
    private let logger = Logger(subsystem: "A2A", category: "LoggingHandler")
    #endif

    // MARK: - Initialisation

    /// Creates a ``LoggingHandler``.
    ///
    /// - Parameter config: Logging options. Defaults to informational level,
    ///   no payload logging.
    public init(config: LoggingConfig = LoggingConfig()) {
        self.config = config
    }

    // MARK: - A2AHandler

    public override func handleRequest(_ request: [String: Any]) async throws -> [String: Any] {
        let method = request["method"] as? String ?? "(unknown)"
        let requestId = request["id"] as? Int ?? -1

        lock.withLock { _startTimes[requestId] = Date() }

        if config.logPayload, let params = request["params"] {
            write(level: config.level,
                  "→ [\(requestId)] \(method) params=\(params)")
        } else {
            write(level: config.level,
                  "→ [\(requestId)] \(method)")
        }

        return request
    }

    public override func handleResponse(_ response: [String: Any]) async throws -> [String: Any] {
        // Reconstruct method + id from the response dict if available,
        // or fall back to unknown (early-return responses may carry these).
        let method = response["method"] as? String ?? "(unknown)"
        let requestId = response["id"] as? Int ?? -1

        let elapsed: String
        if let start = lock.withLock({ _startTimes.removeValue(forKey: requestId) }) {
            let ms = Date().timeIntervalSince(start) * 1_000
            elapsed = String(format: "%.2fms", ms)
        } else {
            elapsed = "?"
        }

        if let errorDict = response["error"] as? [String: Any] {
            let code = errorDict["code"] as? Int ?? 0
            let msg  = errorDict["message"] as? String ?? ""
            write(level: config.errorLevel,
                  "✗ [\(requestId)] \(method) failed in \(elapsed) — code=\(code) \(msg)")
        } else {
            if config.logPayload, let result = response["result"] {
                write(level: config.level,
                      "← [\(requestId)] \(method) finished in \(elapsed) result=\(result)")
            } else {
                write(level: config.level,
                      "← [\(requestId)] \(method) finished in \(elapsed)")
            }
        }

        return response
    }

    // MARK: - Private

    private func write(level: LoggingConfig.LogLevel, _ message: String) {
        #if canImport(os)
        logger.log(level: level.osLogType, "\(message, privacy: .public)")
        #else
        print("[A2A] \(message)")
        #endif
    }
}
