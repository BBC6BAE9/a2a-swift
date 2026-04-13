# A2A Swift SDK - Architecture Documentation

## System Architecture

### High-Level Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Application Code                          │
└──────────────────────┬──────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                     A2AClient                                    │
│  - JSON-RPC 2.0 protocol implementation                          │
│  - 10 RPC methods (message, task, notification)                 │
│  - Thread-safe request ID management                            │
│  - Async/await API                                              │
└──────────────┬──────────────────────────────────────────────────┘
               │
       ┌───────┴─────────┬─────────────┬─────────────┐
       │                 │             │             │
       ▼                 ▼             ▼             ▼
   ┌────────┐    ┌────────────┐   ┌────────┐   ┌────────────┐
   │Handler │    │Marshaling  │   │Error   │   │Validation  │
   │Pipeline│    │(Codable)   │   │Mapping │   │            │
   └─────┬──┘    └────────────┘   └────────┘   └────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                  A2ATransport Protocol                           │
│  - get(url, headers)                                            │
│  - send(url, body, headers)                                     │
│  - sendStream(url, body, headers)                               │
│  - close()                                                      │
└─────────────────────────────────────────────────────────────────┘
         │
    ┌────┴────────────────────┬─────────────────┐
    │                         │                 │
    ▼                         ▼                 ▼
┌──────────────┐      ┌──────────────┐    ┌──────────────┐
│ HttpTransport│      │SseTransport  │    │ MockTransport│
│ (URLSession) │      │(SSE Streaming)    (Testing)     │
└──────────────┘      └──────────────┘    └──────────────┘
    │                         │
    │                    ┌────┴──────┐
    │                    │            │
    │                    ▼            ▼
    │             ┌────────────┐  ┌──────────┐
    │             │ SseParser  │  │Validation│
    │             │(JSON-RPC)  │  │(Events)  │
    │             └────────────┘  └──────────┘
    │
    ▼
    HTTP (GET/POST)
    ▼
Remote Agent Server
```

### Data Flow

#### Message Send Flow

```
Application
    ↓
messageSend(taskId, message)
    ↓
A2AClient.messageSend()
    ├─ Generate request ID (thread-safe)
    ├─ Create JSON-RPC request
    ├─ Run through handler pipeline (onRequest)
    ├─ Codable marshaling: A2AMessage → [String: Any]
    ├─ Validate JSON structure
    ↓
A2ATransport.send()
    ├─ HttpTransport: POST request
    ├─ Set headers (Content-Type, Authorization)
    ├─ JSONSerialization
    ↓
HTTP POST to remote agent
    ↓
Parse response JSON
    ├─ Check for JSON-RPC error field
    ├─ Extract result
    ├─ Codable marshaling: [String: Any] → A2AMessage
    ↓
Run through handler pipeline (onResponse)
    ↓
Return A2AMessage
    ↓
Application
```

#### Message Stream Flow

```
Application
    ↓
messageStream(taskId, messages)
    ↓
A2AClient.messageStream()
    ├─ Create AsyncThrowingStream
    ├─ Call transport.sendStream()
    ↓
SseTransport.sendStream()
    ├─ POST to SSE endpoint
    ├─ URLSession.bytes streaming
    ├─ Parse lines with SseParser
    ↓
SseParser
    ├─ Accumulate multi-line data: fields
    ├─ Extract JSON-RPC response
    ├─ Validate result/error
    ├─ Emit A2AEvent via AsyncThrowingStream
    ↓
Application: for try await event in stream
```

### Module Isolation

#### Core Module (Data Models)

**Purpose**: Define all data types used in A2A protocol

**Dependencies**: Foundation only

**Exports**:
- Task state machine (A2ATask, TaskState, TaskStatus, Artifact)
- Messages (A2AMessage, Part, FileContent)
- Events (A2AEvent)
- Security schemes (SecurityScheme, OAuthFlows, OAuthFlow)
- Agent metadata (AgentCard, AgentSkill, AgentCapabilities, etc.)
- RPC models (ListTasksParams, ListTasksResult)
- Notifications (PushNotificationConfig, etc.)
- Utilities (AnyCodable as JSONObject)

**Design**:
- No circular dependencies
- All types are Codable and Sendable
- Discriminated unions for type-safe parsing
- No async code (all sync Codable)

#### Client Module (Transport and RPC)

**Purpose**: Implement JSON-RPC 2.0 protocol over HTTP/SSE

**Dependencies**: Foundation, Core module

**Key Components**:
- **A2AClient**: Facade for RPC calls
- **A2ATransport**: Protocol for pluggable transports
- **HttpTransport**: URLSession-based HTTP
- **SseTransport**: Server-Sent Events streaming
- **Error handling**: A2ATransportError with localization
- **Middleware**: A2AHandler pipeline

**Design**:
- All I/O is async
- Protocol-oriented (A2ATransport)
- Thread-safe (NSLock for requestId)
- Sendable compliance for concurrency

## Type System

### Discriminated Unions

Used for type-safe parsing of polymorphic types:

#### SecurityScheme Example

```swift
// JSON input
{
  "type": "oauth2",
  "flows": { ... }
}

// Decoded to
SecurityScheme.oauth2(description: nil, flows: ...)

// Manual Codable:
public init(from decoder: Decoder) throws {
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "oauth2":
        let flows = try container.decode(OAuthFlows.self, forKey: .flows)
        self = .oauth2(description: ..., flows: flows)
    // ...
    }
}
```

#### A2AEvent Example

Three event types discriminated by "kind" field:

```swift
enum A2AEvent {
    case statusUpdate(TaskStatus)
    case taskStatusUpdate(A2ATask)
    case artifactUpdate(Artifact)
}
```

### Type Erasure

AnyCodable supports arbitrary JSON structures:

```swift
indirect enum AnyCodable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])  // Recursive
}

typealias JSONObject = [String: AnyCodable]
```

**Use cases**:
- Metadata fields that accept any JSON
- Extension parameters
- Error data payloads
- Dynamic agent capabilities

## Concurrency Model

### Swift Concurrency (Async/Await)

All I/O operations are async:

```swift
// Client API
func messageSend(...) async throws -> A2AMessage
func messageStream(...) async throws -> AsyncThrowingStream<A2AEvent, Error>
func getTask(...) async throws -> A2ATask
func listTasks(...) async throws -> (tasks: [A2ATask], ...)
```

**Benefits**:
- Structured concurrency
- Compiler-enforced thread safety
- No callback hell
- Natural flow control

### AsyncThrowingStream for Streaming

SSE events yielded to AsyncThrowingStream:

```swift
// Producer side (SseTransport)
return AsyncThrowingStream { continuation in
    // ... SSE parsing ...
    continuation.yield(event)
    continuation.finish()
}

// Consumer side (Application)
let stream = try await client.messageStream(...)
for try await event in stream {
    // Handle each event
}
```

### Sendable Compliance

All public types conform to Sendable:

```swift
// Data types
public struct A2AMessage: Codable, Sendable, Equatable
public enum SecurityScheme: Codable, Sendable, Equatable
public enum A2AEvent: Codable, Sendable, Equatable

// Transport
public class HttpTransport: A2ATransport, @unchecked Sendable
```

**NSLock for shared mutable state**:

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

## Error Handling

### Error Hierarchy

```
A2ATransportError (enum)
├── jsonRpc(code, message, data)      # JSON-RPC error response
├── taskNotFound(String)              # Task doesn't exist
├── taskNotCancelable(String)         # Can't cancel this task
├── pushNotificationNotSupported      # Agent doesn't support it
├── pushNotificationConfigNotFound    # Config not found
├── http(statusCode, body)            # HTTP error
├── network(Error)                    # URLSession error
├── parsing(String)                   # JSON parse error
└── unsupportedOperation(String)      # Not implemented
```

### LocalizedError

Each case provides user-friendly error descriptions:

```swift
public var errorDescription: String? {
    switch self {
    case .jsonRpc(let code, let message, _):
        return "JSON-RPC Error (\(code)): \(message)"
    case .taskNotFound(let id):
        return "Task '\(id)' not found"
    case .http(let code, let body):
        return "HTTP \(code): \(body)"
    // ...
    }
}
```

### Error Mapping

Agent errors → A2ATransportError:

```swift
// Detect specific error codes
if let code = rpcError.code {
    switch code {
    case -32001: return .taskNotFound(id)
    case -32002: return .taskNotCancelable(id)
    case -32600: return .pushNotificationNotSupported
    // ...
    }
}
```

## JSON-RPC 2.0 Implementation

### Request Format

```swift
{
  "jsonrpc": "2.0",
  "method": "tasks/send_message",
  "params": {
    "task_id": "task-123",
    "message": { ... }
  },
  "id": 1
}
```

### Response Format

Success:
```json
{
  "jsonrpc": "2.0",
  "result": { ... },
  "id": 1
}
```

Error:
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32001,
    "message": "Task not found",
    "data": { ... }
  },
  "id": 1
}
```

### Implementation

```swift
class A2AClient {
    // Build request
    var request = [
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": nextRequestId()
    ] as [String: Any]
    
    // Send via transport
    let response = try await transport.send(...)
    
    // Parse response
    if let error = response["error"] as? [String: Any] {
        throw mapRpcError(error)
    }
    
    return response["result"]
}
```

## Protocol-Oriented Design

### A2ATransport Protocol

```swift
public protocol A2ATransport: Sendable {
    func get(url: URL, headers: [String: String]) 
        async throws -> [String: Any]
    
    func send(url: URL, body: [String: Any], headers: [String: String]) 
        async throws -> [String: Any]
    
    func sendStream(url: URL, body: [String: Any], headers: [String: String]) 
        async throws -> AsyncThrowingStream<[String: Any], Error>
    
    func close() async throws
}
```

**Implementations**:
- HttpTransport: Real HTTP client
- SseTransport: SSE streaming (extends HttpTransport)
- MockTransport: Testing (not included, can be added)

**Benefits**:
- Easy to test with mocks
- Support multiple transports
- Future: gRPC, WebSocket, etc.

### A2AHandler Protocol

```swift
public protocol A2AHandler {
    func onRequest(_ req: inout A2ARequest) async throws
    func onResponse(_ res: inout A2AResponse) async throws
}

struct A2AHandlerPipeline {
    let handlers: [A2AHandler]
    
    func apply(request: inout A2ARequest) async throws {
        // Forward through handlers
        for handler in handlers {
            try await handler.onRequest(&request)
        }
    }
    
    func apply(response: inout A2AResponse) async throws {
        // Backward through handlers
        for handler in handlers.reversed() {
            try await handler.onResponse(&response)
        }
    }
}
```

**Use cases**:
- Logging/debugging
- Authentication header injection
- Request/response transformation
- Metrics collection

## Marshaling Strategy

### Codable ↔ [String: Any] Bridge

Core module types are Codable, but transport uses [String: Any]:

```swift
// Encode: A2AMessage → [String: Any]
func encodeToDict<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

// Decode: [String: Any] → A2AMessage
func decodeFromDict<T: Decodable>(_ dict: [String: Any]) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(T.self, from: data)
}
```

**Why this approach**:
- URLSession uses [String: Any]
- JSON-RPC uses [String: Any]
- Codable provides type safety in core layer
- Bridge functions at transport layer

## Testing Strategy

### Protocol-Based Mocking

Mock transport for unit tests:

```swift
class MockTransport: A2ATransport {
    var getRequests: [URL] = []
    var sendRequests: [(URL, [String: Any])] = []
    var responses: [[String: Any]] = []
    
    func send(url: URL, body: [String: Any], headers: [String: String]) 
        async throws -> [String: Any] {
        sendRequests.append((url, body))
        return responses.removeFirst()
    }
}
```

### Unit Test Example

```swift
func testMessageSend() async throws {
    let mock = MockTransport()
    mock.responses = [[
        "jsonrpc": "2.0",
        "result": [
            "role": "agent",
            "parts": [...]
        ],
        "id": 1
    ]]
    
    let client = A2AClient(transport: mock)
    let response = try await client.messageSend(
        taskId: "task-123",
        message: testMessage
    )
    
    XCTAssertEqual(response.role, .agent)
}
```

## Performance Considerations

### Memory

- **Streaming**: Events are processed one at a time (no buffering)
- **Marshaling**: JSON serialization at transport boundary only
- **AnyCodable**: Recursive indirect enum (stack allocation)

### CPU

- **Codable**: Standard library optimization
- **Async/await**: Compiler optimizes to state machines
- **NSLock**: Minimal contention (only for requestId)

### Network

- **SSE**: Efficient long-polling with streaming
- **HTTP**: Standard URLSession connection pooling
- **JSON-RPC**: Minimal request overhead (just metadata)

## Deployment Targets

| Platform | Minimum | Reason |
|----------|---------|--------|
| iOS | 13.0 | URLSession.bytes (async sequences) |
| macOS | 10.15 | Catalina: async/await support |
| tvOS | 13.0 | Async support |
| watchOS | 6.0 | Foundation + URLSession |

**Swift Requirements**:
- Swift 5.5+ (async/await)
- Swift 5.7+ (recommended, improved Sendable)

## Zero Dependency Philosophy

All functionality uses Foundation and Swift Standard Library:

| Feature | Framework |
|---------|-----------|
| HTTP | Foundation.URLSession |
| JSON | Foundation.JSONSerialization, Codable |
| Concurrency | Swift.async/await |
| Thread Safety | Foundation.NSLock |
| Dates | Foundation.Date |
| UUID | Foundation.UUID |

**Advantages**:
- Minimal binary size
- Fewer security vulnerabilities
- No dependency version conflicts
- Faster build times
- Easy integration

## Future Extensibility

### Planned Enhancements

1. **gRPC Transport**: Protocol buffers for efficiency
2. **WebSocket Transport**: Real-time bidirectional communication
3. **Middleware**: Built-in logging, metrics, auth
4. **Caching**: Response caching layer
5. **Retry Logic**: Exponential backoff
6. **Rate Limiting**: Built-in rate limiter

### Extension Points

1. **Custom Transports**: Implement A2ATransport
2. **Custom Handlers**: Implement A2AHandler
3. **Error Mapping**: Override error handling
4. **Type Extensions**: Add custom Part types

All achieved through protocol-oriented design.
