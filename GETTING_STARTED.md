# A2A Swift SDK - Getting Started Guide

## Quick Start (5 minutes)

### Installation

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/your-org/a2a-swift", from: "1.0.0"),
```

### Using the Client

```swift
import A2A

// Create a client
let client = A2AClient(url: "https://agent.example.com")

// Send a message
let response = try await client.sendMessage(
    SendMessageRequest.with {
        $0.message = Message.with {
            $0.messageID = UUID().uuidString
            $0.role = .user
            $0.parts = [Part.with { $0.text = "Hello, agent!" }]
        }
    }
)

// Handle response
switch response {
case .message(let msg):
    print("Agent replied:", msg.parts.first?.text ?? "")
case .task(let task):
    print("Started task:", task.taskID)
}
```

### Running the Server

```swift
import A2A

// Create a simple agent
class EchoAgent: AgentExecutor {
    func execute(_ context: ExecutorContext) async -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Echo back the message
                let reply = Message.with {
                    $0.messageID = UUID().uuidString
                    $0.role = .model
                    $0.parts = [Part.with { $0.text = "Echo: \(context.message.parts.first?.text ?? "")" }]
                }
                continuation.yield(.message(reply))
                continuation.finish()
            }
        }
    }
}

// Start server
let agent = EchoAgent()
let card = AgentCard.with {
    $0.displayName = "Echo Agent"
    $0.apiVersion = "v1"
}
let server = A2AServer(handler: DefaultRequestHandler(executor: agent), agentCard: card)

// Use with your HTTP framework (e.g., Vapor):
app.post("/") { req async in
    let serverReq = ServerRequest(
        method: "POST",
        path: "/",
        headers: req.headers.dictionary,
        body: req.body.readableBytes.count > 0 ? Data(req.body) : nil
    )
    switch await server.handle(serverReq) {
    case .response(let r):
        return Response(status: HTTPResponseStatus(statusCode: r.statusCode), body: Response.Body(data: r.body ?? Data()))
    case .stream(let s):
        return Response(status: .ok, body: streamSSE(s.lines))
    }
}
```

---

## Documentation Map

### For Getting Oriented
- **Start here:** `README.md` - Overview and basic examples
- **Next:** `PROJECT_STATUS.md` - Current state and accomplishments
- **Then:** `PHASE_8_DOCS_INDEX.md` - Detailed documentation guide

### For Building Clients
- `PHASE_8_SWIFT_PATTERNS.md` - Client implementation patterns
- `PHASE_8_REFERENCE.md` - API reference with Go mappings
- `README.md` - Client usage examples

### For Building Servers
- `PHASE_8_README.md` - Architecture overview
- `PHASE_8_REFERENCE.md` - Server component reference
- `PHASE_8_SWIFT_PATTERNS.md` - Working server implementation example

### For Advanced Topics
- `PHASE_8_SWIFT_PATTERNS.md` - Middleware, streaming, error handling
- `PHASE_8_REFERENCE.md` - Task management, state machines
- Source code comments - Inline documentation

### For Setup and Contribution
- `PHASE_8_STARTUP_CHECKLIST.md` - Developer setup
- `TODO.md` - Feature completeness status
- Git commits - Change history and reasoning

---

## Architecture Overview

### Client SDK

The client is transport-agnostic and uses a middleware pipeline:

```
Request
   ↓
[Auth Middleware] → [Logging Middleware] → [Custom Middleware]
   ↓                    ↓                        ↓
[JSON-RPC Transport] or [REST Transport]
   ↓
Response
   ↓
[Custom Middleware] → [Logging Middleware] → [Auth Middleware]
   ↓
Application
```

### Server SDK

The server is framework-agnostic and handles JSON-RPC protocol:

```
HTTP Request
   ↓
A2AServer (JSON-RPC parsing)
   ↓
[Method Dispatcher] → DefaultRequestHandler
   ↓
[AgentExecutor] (streaming)
   ↓
[TaskUpdateManager] (state machine)
   ↓
SSE or HTTP Response
```

---

## Key Features

### ✅ Client Features
- [x] JSON-RPC 2.0 protocol
- [x] Server-Sent Events (SSE) streaming
- [x] REST transport for legacy agents
- [x] Middleware pipeline for cross-cutting concerns
- [x] Automatic error handling with typed errors
- [x] Multi-tenant support
- [x] Authentication system with session management
- [x] Task-local context for correlation IDs
- [x] v0.3 protocol compatibility

### ✅ Server Features
- [x] Framework-agnostic HTTP handler
- [x] JSON-RPC 2.0 dispatch
- [x] SSE streaming support
- [x] Task management with state machine
- [x] Push notifications
- [x] Agent card hosting
- [x] Extensible agent executor interface

### ✅ Quality Metrics
- [x] 152 comprehensive tests (100% passing)
- [x] Full async/await support
- [x] StrictConcurrency enabled
- [x] Sendable types throughout
- [x] Multi-platform support (iOS 16+, macOS 13+, tvOS 16+, watchOS 9+, visionOS 1+)

---

## Common Tasks

### Add Authentication

```swift
import A2A

let credentials = InMemoryCredentialsStore()
credentials.store("session-123", credential: AuthCredential.with {
    $0.scheme = .bearer
    $0.token = "my-auth-token"
})

let authHandler = AuthHandler(credentialsService: credentials)
let client = A2AClient(
    url: "https://agent.example.com",
    handlers: [authHandler]
)
```

### Add Logging

```swift
let loggingHandler = LoggingHandler(
    level: .debug,
    logPayload: true
)

let client = A2AClient(
    url: "https://agent.example.com",
    handlers: [loggingHandler]
)
```

### Customize Agent Card Resolution

```swift
let resolver = AgentCardResolver()
    .withPath("/.custom/agent-card.json")
    .withRequestHeader("X-API-Key", "secret-key")

let client = A2AClient(
    url: "https://agent.example.com",
    cardResolver: resolver
)
```

### Handle Streaming

```swift
for try await event in try await client.messageStream(request) {
    switch event {
    case .message(let msg):
        print("Message:", msg.parts.first?.text ?? "")
    case .statusUpdate(let status):
        print("Status:", status.state)
    case .artifactUpdate(let artifact):
        print("Artifact:", artifact.uri)
    case .task(let task):
        print("Task:", task.state)
    }
}
```

---

## Testing

Run all tests:
```bash
cd /path/to/a2a-swift
swift test
```

Run specific test:
```bash
swift test --filter "AgentCardResolverTests"
```

Run with verbose output:
```bash
swift test --verbose
```

---

## Troubleshooting

### Build Issues

**Error: "Package dependency graph is invalid"**
- Run: `swift package update`
- Then: `swift build -v`

**Error: "StrictConcurrency not available"**
- Requires Swift 5.9+
- Update Xcode to 15.0+

### Runtime Issues

**"Task not found" error**
- Ensure the task ID is correct
- Check if the task has been completed or canceled

**"Method not found" error**
- Verify the agent supports the requested method
- Check the agent's capabilities in the AgentCard

**SSE connection drops**
- This is normal; SSE closes after sending the final event
- Check logs for actual errors in previous events

---

## Next Steps

1. **Explore the Examples**
   - Check `PHASE_8_SWIFT_PATTERNS.md` for working code examples

2. **Review the Architecture**
   - Read `PHASE_8_README.md` for design decisions

3. **Check the Tests**
   - Look in `Tests/A2ATests/` for real test scenarios
   - Each test demonstrates a specific feature

4. **Build Something**
   - Create a simple echo agent (see Server Quick Start above)
   - Connect a client to test locally

5. **Integrate**
   - Add to your application using the Installation instructions
   - Use the middleware patterns for your custom logic

---

## Support

For questions or issues:
1. Check the documentation files listed above
2. Review the inline code documentation
3. Look at the test cases for examples
4. Check the git commit history for context on changes

---

## License

Apache License 2.0 - See LICENSE file for details.

