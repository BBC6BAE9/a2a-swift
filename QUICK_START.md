# A2A Swift SDK - Quick Start Guide

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/google/a2a-swift.git", from: "1.0.0")
```

Or in Xcode:
1. File → Add Packages
2. Enter: `https://github.com/google/a2a-swift.git`
3. Select version 1.0.0 or later

### Manual Integration

Copy the Core and Client directories to your project.

## Basic Setup

```swift
import A2A

// Create a transport
let transport = HttpTransport()

// Create a client
let client = A2AClient(transport: transport)
```

## Common Tasks

### 1. Send a Message

```swift
// Create a message
let message = A2AMessage(
    role: .user,
    parts: [
        .text(text: "Hello agent!", metadata: nil)
    ]
)

// Send to an agent
do {
    let response = try await client.messageSend(
        taskId: "task-123",
        message: message
    )
    print("Agent response: \(response)")
} catch {
    print("Error: \(error.localizedDescription)")
}
```

### 2. Stream Messages (Real-time Updates)

```swift
let stream = try await client.messageStream(
    taskId: "task-123",
    messages: [message]
)

for try await event in stream {
    switch event {
    case .statusUpdate(let status):
        print("Status changed: \(status)")
        
    case .taskStatusUpdate(let task):
        print("Task state: \(task.state)")
        
    case .artifactUpdate(let artifact):
        print("New artifact: \(artifact)")
    }
}
```

### 3. Get Task Status

```swift
do {
    let task = try await client.getTask(taskId: "task-123")
    print("Task state: \(task.state)")
    print("Last updated: \(task.lastUpdatedTime ?? Date())")
} catch {
    print("Error: \(error.localizedDescription)")
}
```

### 4. List Tasks

```swift
do {
    let (tasks, totalSize, nextToken) = try await client.listTasks(
        filter: "state:running",
        pageSize: 10
    )
    
    print("Found \(tasks.count) tasks")
    if let total = totalSize {
        print("Total: \(total)")
    }
} catch {
    print("Error: \(error.localizedDescription)")
}
```

### 5. Cancel a Task

```swift
do {
    try await client.cancelTask(taskId: "task-123")
    print("Task cancelled")
} catch {
    print("Error: \(error.localizedDescription)")
}
```

### 6. Configure Push Notifications

```swift
do {
    let config = PushNotificationConfig(
        url: URL(string: "https://callback.example.com/notify")!,
        token: "secret-token"
    )
    
    let taskConfig = TaskPushNotificationConfig(
        taskId: "task-123",
        pushNotificationConfig: config
    )
    
    try await client.setPushNotificationConfig(taskConfig)
    print("Push notifications configured")
} catch {
    print("Error: \(error.localizedDescription)")
}
```

### 7. Get Push Notification Config

```swift
do {
    let config = try await client.getPushNotificationConfig(
        taskId: "task-123"
    )
    print("Callback URL: \(config.url)")
} catch {
    print("Error: \(error.localizedDescription)")
}
```

## Message Types

### Text Messages

```swift
let textMessage = A2AMessage(
    role: .user,
    parts: [
        .text(
            text: "What is 2+2?",
            metadata: [
                "source": .string("calculator"),
                "priority": .int(1)
            ]
        )
    ]
)
```

### File Messages

```swift
// Reference a file by URI
let uriPart = Part.file(
    file: .uri(
        uri: "https://example.com/document.pdf",
        name: "document.pdf",
        mimeType: "application/pdf"
    ),
    metadata: nil
)

// Or embed file content as base64
let bytesPart = Part.file(
    file: .bytes(
        bytes: "SGVsbG8gV29ybGQ=",  // "Hello World" in base64
        name: "hello.txt",
        mimeType: "text/plain"
    ),
    metadata: nil
)

let fileMessage = A2AMessage(
    role: .user,
    parts: [uriPart, bytesPart]
)
```

### Structured Data Messages

```swift
let dataPart = Part.data(
    data: [
        "name": .string("Alice"),
        "age": .int(30),
        "email": .string("alice@example.com")
    ],
    metadata: nil
)

let dataMessage = A2AMessage(
    role: .agent,
    parts: [dataPart]
)
```

### Mixed Content Messages

```swift
let message = A2AMessage(
    role: .user,
    parts: [
        .text(text: "Here's a document:", metadata: nil),
        .file(file: .uri(uri: "file.pdf"), metadata: nil),
        .text(text: "Please process it.", metadata: nil),
        .data(data: ["format": .string("summary")], metadata: nil)
    ]
)
```

## Error Handling

### Handling Different Error Types

```swift
do {
    try await client.getTask(taskId: "task-123")
} catch let error as A2ATransportError {
    switch error {
    case .taskNotFound(let id):
        print("Task '\(id)' not found")
        
    case .taskNotCancelable(let id):
        print("Cannot cancel task '\(id)' - already completed")
        
    case .http(let statusCode, let body):
        print("HTTP \(statusCode): \(body)")
        
    case .network(let underlyingError):
        print("Network error: \(underlyingError)")
        
    case .parsing(let description):
        print("Failed to parse response: \(description)")
        
    case .pushNotificationNotSupported:
        print("Agent doesn't support push notifications")
        
    case .jsonRpc(let code, let message, let data):
        print("RPC Error \(code): \(message)")
        if let data = data {
            print("Details: \(data)")
        }
        
    default:
        print("Other error: \(error.localizedDescription)")
    }
} catch {
    print("Unexpected error: \(error)")
}
```

## Advanced Usage

### Custom Transport

Implement your own transport for testing or special requirements:

```swift
class CustomTransport: A2ATransport {
    func get(url: URL, headers: [String: String]) async throws -> [String: Any] {
        // Custom implementation
    }
    
    func send(url: URL, body: [String: Any], headers: [String: String]) 
        async throws -> [String: Any] {
        // Custom implementation
    }
    
    func sendStream(url: URL, body: [String: Any], headers: [String: String]) 
        async throws -> AsyncThrowingStream<[String: Any], Error> {
        // Custom implementation
    }
    
    func close() async throws {
        // Clean up
    }
}

let client = A2AClient(transport: CustomTransport())
```

### Using SSE Transport for Streaming

```swift
// Use SSE transport for better streaming support
let transport = SseTransport()
let client = A2AClient(transport: transport)

// Streaming will now use Server-Sent Events
let stream = try await client.messageStream(
    taskId: "task-123",
    messages: messages
)

for try await event in stream {
    // Handle event
}
```

### Middleware for Custom Logic

```swift
class LoggingHandler: A2AHandler {
    func onRequest(_ req: inout A2ARequest) async throws {
        print("→ Request: \(req.method)")
    }
    
    func onResponse(_ res: inout A2AResponse) async throws {
        print("← Response: \(res.statusCode)")
    }
}

let handler = LoggingHandler()
let pipeline = A2AHandlerPipeline(handlers: [handler])

let client = A2AClient(transport: transport, handlers: pipeline)
```

## Concurrency Tips

### Running in Main Actor

```swift
@MainActor
func updateUI() async throws {
    let message = try await client.messageSend(
        taskId: "task-123",
        message: message
    )
    // Update UI with result
}
```

### Background Task

```swift
Task.detached {
    do {
        let stream = try await client.messageStream(...)
        for try await event in stream {
            // Process events
        }
    } catch {
        print("Error: \(error)")
    }
}
```

### Concurrent Requests

```swift
async let task1 = client.getTask(taskId: "task-1")
async let task2 = client.getTask(taskId: "task-2")
async let task3 = client.getTask(taskId: "task-3")

let (t1, t2, t3) = try await (task1, task2, task3)
print("Tasks: \(t1), \(t2), \(t3)")
```

## Testing

### Mock Transport for Unit Tests

```swift
class MockTransport: A2ATransport {
    var mockResponse: [String: Any] = [
        "jsonrpc": "2.0",
        "result": ["role": "agent", "parts": []],
        "id": 1
    ]
    
    func send(url: URL, body: [String: Any], headers: [String: String]) 
        async throws -> [String: Any] {
        return mockResponse
    }
    
    // Implement other methods...
}

func testMessageSend() async throws {
    let mock = MockTransport()
    let client = A2AClient(transport: mock)
    
    let response = try await client.messageSend(
        taskId: "task-123",
        message: testMessage
    )
    
    XCTAssertNotNil(response)
}
```

## Common Patterns

### Polling for Task Completion

```swift
func waitForCompletion(taskId: String, timeout: TimeInterval = 300) async throws -> A2ATask {
    let deadline = Date().addingTimeInterval(timeout)
    
    while Date() < deadline {
        let task = try await client.getTask(taskId: taskId)
        
        if task.state == .completed || task.state == .failed || task.state == .cancelled {
            return task
        }
        
        // Wait before polling again
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
    }
    
    throw A2ATransportError.unsupportedOperation("Task did not complete within timeout")
}

let completedTask = try await waitForCompletion(taskId: "task-123")
```

### Batch Processing

```swift
func processBatch(taskIds: [String]) async {
    for taskId in taskIds {
        do {
            let task = try await client.getTask(taskId: taskId)
            print("Task \(taskId): \(task.state)")
        } catch {
            print("Error processing \(taskId): \(error)")
        }
    }
}

await processBatch(taskIds: ["task-1", "task-2", "task-3"])
```

## Debugging

### Enable Verbose Logging

Create a custom handler that logs all requests and responses:

```swift
class DebugHandler: A2AHandler {
    func onRequest(_ req: inout A2ARequest) async throws {
        print("Request: \(req.method)")
        print("Params: \(req.params)")
    }
    
    func onResponse(_ res: inout A2AResponse) async throws {
        print("Response: \(res.result ?? res.error)")
    }
}

let client = A2AClient(
    transport: HttpTransport(),
    handlers: A2AHandlerPipeline(handlers: [DebugHandler()])
)
```

## Performance Optimization

### Connection Pooling

HttpTransport uses URLSession, which automatically pools connections.

### Streaming for Large Results

Use `messageStream()` instead of `messageSend()` for large responses:

```swift
// Efficient for large data
let stream = try await client.messageStream(
    taskId: "task-123",
    messages: [message]
)

// Processes one event at a time
for try await event in stream {
    // Handle each event
}
```

## Next Steps

1. **Read the full README.md** for comprehensive documentation
2. **Review ARCHITECTURE.md** for design details
3. **Check examples/** directory for complete examples
4. **Run tests** to see usage patterns

## Support

For issues or questions:
- Check existing GitHub issues
- Read the documentation
- Submit a new issue with reproducible example

Happy coding! 🎉
