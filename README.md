# A2A Swift SDK

A complete Swift implementation of the Agent-to-Agent (A2A) protocol for establishing secure, bidirectional communication between autonomous agents.

## Overview

A2A is a standardized protocol built on JSON-RPC 2.0 that enables agents to:
- Exchange structured messages and artifacts
- Manage long-running tasks with state transitions
- Stream real-time updates via Server-Sent Events (SSE)
- Use pluggable authentication and security schemes
- Configure push notifications for task updates
- Discover agent capabilities and available skills

This Swift SDK provides a production-ready implementation with:
- **Zero external dependencies** — uses only Swift Foundation and system frameworks
- **Swift Concurrency** — full async/await and AsyncThrowingStream support
- **Type safety** — Codable serialization with discriminated unions
- **Extensibility** — protocol-oriented design for custom transports and middleware
- **OpenAPI 3.0 compliance** — complete security scheme support

## Architecture

### Project Structure

```
A2A-Swift/
├── Core/                          # Data models and protocol definitions
│   ├── A2ATask.swift              # Task state machine and artifacts
│   ├── Message.swift              # Message format (roles, parts)
│   ├── Event.swift                # Streaming event types
│   ├── Part.swift                 # Message parts (text, file, data)
│   ├── AnyCodable.swift           # Type-erased JSON values
│   ├── SecurityScheme.swift       # Authentication schemes (OpenAPI 3.0)
│   ├── AgentCard.swift            # Agent manifest and metadata
│   ├── AgentSkill.swift           # Skill definitions
│   ├── AgentCapabilities.swift    # Feature flags
│   ├── AgentInterface.swift       # Transport protocol endpoints
│   ├── AgentProvider.swift        # Provider information
│   ├── AgentExtension.swift       # Protocol extensions
│   ├── ListTasksParams.swift      # RPC parameters
│   ├── ListTasksResult.swift      # RPC response
│   └── PushNotification.swift     # Notification configuration
│
└── Client/                         # Transport and RPC implementation
    ├── A2AClient.swift            # JSON-RPC 2.0 client
    ├── A2ATransport.swift         # Transport protocol
    ├── HttpTransport.swift        # HTTP/REST implementation
    ├── SseTransport.swift         # SSE streaming
    ├── SseParser.swift            # SSE parsing
    ├── A2ATransportError.swift    # Error types
    └── A2AHandler.swift           # Middleware pipeline
```

### Core Concepts

#### Task Lifecycle

Tasks follow a state machine with transitions:

```
[pending] → [running] → [completed]
   ↓                        ↑
   └────── [cancelled] ─────┘
           [failed]
```

Each state transition includes metadata (start time, end time, updates, etc.) and can include artifacts (output data).

#### Message Format

Messages are the fundamental unit of communication:

```swift
struct A2AMessage {
    let role: Role              // "user" or "agent"
    let parts: [Part]           // Text, files, or structured data
}

enum Part {
    case text(String, metadata: JSONObject?)
    case file(FileContent, metadata: JSONObject?)
    case data(JSONObject, metadata: JSONObject?)
}
```

#### Event Streaming

Three event types for real-time updates via SSE:

```swift
enum A2AEvent {
    case statusUpdate(TaskStatus)
    case taskStatusUpdate(A2ATask)
    case artifactUpdate(Artifact)
}
```

#### Security Schemes

Full OpenAPI 3.0 security scheme support:

```swift
enum SecurityScheme {
    case apiKey(name: String, in: String)
    case http(scheme: String, bearerFormat: String?)
    case oauth2(flows: OAuthFlows)
    case openIdConnect(openIdConnectUrl: String)
    case mutualTls()
}
```

## Core Module

### Data Models

#### A2ATask.swift (165 lines)

Represents task state and lifecycle:

```swift
public struct A2ATask: Codable, Sendable, Equatable {
    let id: String                          // Task identifier
    let state: TaskState                    // Current lifecycle state
    let status: TaskStatus?                 // Current status
    let lastUpdatedTime: Date?              // Last update timestamp
    let artifact: Artifact?                 // Output artifact
}

public enum TaskState: String, Codable, Sendable, Equatable {
    case pending, running, completed, cancelled, failed
}
```

#### Message.swift (91 lines)

Defines the message protocol:

```swift
public enum Role: String, Codable, Sendable, Equatable {
    case user, agent
}

public struct A2AMessage: Codable, Sendable, Equatable {
    let role: Role
    let parts: [Part]
}
```

#### Event.swift (136 lines)

Streaming event types with discriminated union pattern:

```swift
public enum A2AEvent: Codable, Sendable, Equatable {
    case statusUpdate(TaskStatus)
    case taskStatusUpdate(A2ATask)
    case artifactUpdate(Artifact)
    
    // Manual Codable: encodes type field to discriminate variants
}
```

#### Part.swift (171 lines)

Flexible content parts with file support:

```swift
public enum Part: Codable, Sendable, Equatable {
    case text(text: String, metadata: JSONObject?)
    case file(file: FileContent, metadata: JSONObject?)
    case data(data: JSONObject, metadata: JSONObject?)
}

public enum FileContent: Codable, Sendable, Equatable {
    case uri(uri: String, name: String?, mimeType: String?)
    case bytes(bytes: String, name: String?, mimeType: String?)
}
```

#### AnyCodable.swift (137 lines)

Type-erased JSON container:

```swift
public indirect enum AnyCodable: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])
}

public typealias JSONObject = [String: AnyCodable]
```

#### SecurityScheme.swift (198 lines)

OpenAPI 3.0 security schemes:

```swift
public enum SecurityScheme: Codable, Sendable, Equatable {
    case apiKey(description: String?, name: String, in: String)
    case http(description: String?, scheme: String, bearerFormat: String?)
    case oauth2(description: String?, flows: OAuthFlows)
    case openIdConnect(description: String?, openIdConnectUrl: String)
    case mutualTls(description: String?)
}
```

#### Agent Metadata

- **AgentCard.swift** (122 lines): Complete agent manifest with capabilities
- **AgentSkill.swift** (74 lines): Skill definition with metadata
- **AgentCapabilities.swift** (55 lines): Feature flags (streaming, push notifications, etc.)
- **AgentInterface.swift** (55 lines): Transport protocol endpoint
- **AgentProvider.swift** (37 lines): Provider organization info
- **AgentExtension.swift** (62 lines): Protocol extension definition

### RPC Models

- **ListTasksParams.swift** (74 lines): Pagination and filtering parameters
- **ListTasksResult.swift** (52 lines): Task list response with pagination
- **PushNotification.swift** (88 lines): Notification configuration

## Client Module

### A2AClient.swift (632 lines)

Main JSON-RPC 2.0 client with thread-safe request ID management:

#### RPC Methods

**Message Operations:**
```swift
func messageSend(
    taskId: String,
    message: A2AMessage
) async throws -> A2AMessage

func messageStream(
    taskId: String,
    messages: [A2AMessage]
) async throws -> AsyncThrowingStream<A2AEvent, Error>
```

**Task Management:**
```swift
func getTask(taskId: String) async throws -> A2ATask

func listTasks(
    filter: String? = nil,
    pageSize: Int? = nil,
    pageToken: String? = nil
) async throws -> (tasks: [A2ATask], totalSize: Int?, nextPageToken: String?)

func cancelTask(taskId: String) async throws

func resubscribeToTask(taskId: String) async throws -> AsyncThrowingStream<A2AEvent, Error>
```

**Push Notifications:**
```swift
func setPushNotificationConfig(
    config: TaskPushNotificationConfig
) async throws

func getPushNotificationConfig(taskId: String) async throws -> PushNotificationConfig

func listPushNotificationConfigs() async throws -> [TaskPushNotificationConfig]

func deletePushNotificationConfig(taskId: String) async throws
```

**Implementation Details:**
- Thread-safe request ID counter with NSLock
- Automatic request/response marshaling via Codable
- Comprehensive error mapping to A2ATransportError
- Support for custom middleware via A2AHandler pipeline

### Transport Layer

#### A2ATransport.swift (111 lines)

Protocol defining transport interface:

```swift
public protocol A2ATransport: Sendable {
    func get(url: URL, headers: [String: String]) async throws -> [String: Any]
    func send(url: URL, body: [String: Any], headers: [String: String]) async throws -> [String: Any]
    func sendStream(url: URL, body: [String: Any], headers: [String: String]) 
        async throws -> AsyncThrowingStream<[String: Any], Error>
    func close() async throws
}
```

#### HttpTransport.swift (193 lines)

URLSession-based HTTP client:

```swift
public class HttpTransport: A2ATransport {
    // GET request handling
    // POST request handling
    // Header merging and validation
    // Status code and JSON validation
    // Sendable support via @unchecked Sendable
}
```

#### SseTransport.swift (173 lines)

Server-Sent Events streaming:

```swift
public class SseTransport: HttpTransport {
    override func sendStream(
        url: URL,
        body: [String: Any],
        headers: [String: String]
    ) async throws -> AsyncThrowingStream<[String: Any], Error>
}
```

#### SseParser.swift (150 lines)

Parses SSE format into JSON-RPC responses:

```swift
struct SseParser {
    // Accumulates multi-line data: fields
    // Extracts JSON-RPC result or error
    // Throws on error responses
    // Handles stream termination
}
```

### Error Handling

#### A2ATransportError.swift (103 lines)

Comprehensive error types:

```swift
public enum A2ATransportError: LocalizedError {
    case jsonRpc(code: Int, message: String, data: JSONObject?)
    case taskNotFound(String)
    case taskNotCancelable(String)
    case pushNotificationNotSupported
    case pushNotificationConfigNotFound(String)
    case http(statusCode: Int, body: String)
    case network(Error)
    case parsing(String)
    case unsupportedOperation(String)
}
```

Each error provides localized descriptions and underlying context.

### Middleware

#### A2AHandler.swift (120 lines)

Extensible middleware pipeline:

```swift
public protocol A2AHandler {
    func onRequest(_ req: inout A2ARequest) async throws
    func onResponse(_ res: inout A2AResponse) async throws
}

struct A2AHandlerPipeline {
    // Symmetric pipeline: requests forward, responses backward
    // Allows multiple handlers for logging, auth, metrics, etc.
}
```

## Design Patterns

### Discriminated Unions

Manual Codable implementations for type-safe parsing:

```swift
// In SecurityScheme.swift
public init(from decoder: Decoder) throws {
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "apiKey": ...
    case "http": ...
    // etc.
    }
}
```

### Type Erasure

AnyCodable enables flexible JSON structures:

```swift
public indirect enum AnyCodable {
    case object([String: AnyCodable])
    // Recursive structure for arbitrary JSON
}
```

### Protocol-Oriented Design

Transport layer based on protocols for easy testing and extension:

```swift
public protocol A2ATransport: Sendable {
    // Define transport contract
    // Allow custom implementations (mocking, etc.)
}
```

### Thread Safety

NSLock for concurrent access:

```swift
class A2AClient {
    private let requestIdLock = NSLock()
    private var requestIdCounter = 0
    
    private func nextRequestId() -> Int {
        requestIdLock.withLock {
            requestIdCounter += 1
            return requestIdCounter
        }
    }
}
```

### Sendable Compliance

Thread-safe concurrency support:

```swift
public struct A2AMessage: Codable, Sendable, Equatable
public class HttpTransport: A2ATransport, @unchecked Sendable
```

## Swift Concurrency Model

### Async/Await

All I/O operations are async:

```swift
let message = try await client.messageSend(...)
let tasks = try await client.listTasks(...)
```

### Streaming with AsyncThrowingStream

Real-time event streaming:

```swift
let stream = try await client.messageStream(...)
for try await event in stream {
    // Handle event
}
```

### Actor and Sendable

- All types conform to Sendable for thread-safe sharing
- HttpTransport marked @unchecked Sendable (internal synchronization)
- NSLock for fine-grained concurrency control

## Dependencies

### Framework Dependencies

- **Foundation**: JSON encoding/decoding, URLSession, UUID, Date
- **os**: No OS-specific logging used (possible future enhancement)
- **Swift Standard Library**: Collections, algorithms

### Platform Support

- **iOS**: 13.0+
- **macOS**: 10.15+
- **tvOS**: 13.0+
- **watchOS**: 6.0+

**Zero external package dependencies** — no CocoaPods, no SPM dependencies.

## Error Handling

### Strategy

- Comprehensive error enum with 9 variants
- LocalizedError for user-friendly messages
- Underlying error context preservation
- JSON-RPC error mapping

### Examples

```swift
do {
    try await client.getTask(taskId: "...")
} catch let error as A2ATransportError {
    switch error {
    case .taskNotFound(let id):
        print("Task \(id) not found")
    case .http(let status, let body):
        print("HTTP \(status): \(body)")
    case .network(let underlyingError):
        print("Network error: \(underlyingError)")
    // etc.
    }
}
```

## Usage Examples

### Creating a Client

```swift
import A2A

let transport = HttpTransport()
let client = A2AClient(transport: transport)
```

### Sending Messages

```swift
let message = A2AMessage(
    role: .user,
    parts: [
        .text(text: "Hello, agent!", metadata: nil)
    ]
)

let response = try await client.messageSend(
    taskId: "task-123",
    message: message
)
```

### Streaming Messages

```swift
let messages = [
    A2AMessage(role: .user, parts: [.text(text: "Start processing", metadata: nil)])
]

let stream = try await client.messageStream(
    taskId: "task-123",
    messages: messages
)

for try await event in stream {
    switch event {
    case .statusUpdate(let status):
        print("Status: \(status)")
    case .taskStatusUpdate(let task):
        print("Task state: \(task.state)")
    case .artifactUpdate(let artifact):
        print("Artifact: \(artifact)")
    }
}
```

### Task Management

```swift
// Get a specific task
let task = try await client.getTask(taskId: "task-123")
print("Task state: \(task.state)")

// List tasks with pagination
let (tasks, total, nextToken) = try await client.listTasks(
    filter: "state:running",
    pageSize: 10
)

// Cancel a task
try await client.cancelTask(taskId: "task-123")
```

### Push Notifications

```swift
let config = PushNotificationConfig(
    url: URL(string: "https://callback.example.com/notify")!,
    token: "secret-token-123"
)

let taskConfig = TaskPushNotificationConfig(
    taskId: "task-123",
    pushNotificationConfig: config
)

try await client.setPushNotificationConfig(taskConfig)
```

## Code Metrics

| Metric | Count |
|--------|-------|
| Total Files | 22 |
| Total Lines | 2,979 |
| Core Module | 13 files (1,497 lines) |
| Client Module | 7 files (1,482 lines) |
| Avg Lines per File | 135 |
| Async Functions | 10+ |
| Error Cases | 9 |
| Type Definitions | 40+ |

## Implementation Quality

✅ **Type Safety**: Full use of Swift type system with discriminated unions
✅ **Concurrency**: Swift Concurrency with async/await and AsyncThrowingStream
✅ **Thread Safety**: NSLock and Sendable compliance
✅ **Error Handling**: Comprehensive error types with localized descriptions
✅ **Zero Dependencies**: No external package dependencies
✅ **Protocol-Oriented**: Extensible design via protocols
✅ **OpenAPI 3.0**: Full security scheme compliance
✅ **Production Ready**: Comprehensive error handling and validation

## License

Apache License 2.0 — See LICENSE file for details.

## Contributing

See CONTRIBUTING.md for development guidelines.
