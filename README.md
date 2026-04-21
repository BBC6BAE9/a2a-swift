# A2A Swift SDK

A Swift client and server SDK for the [Agent-to-Agent (A2A) protocol](https://google.github.io/A2A/), with feature parity to the official Go SDK.

## Requirements

- Swift 5.9+
- iOS 16 / macOS 13 / tvOS 16 / watchOS 9+
- Xcode 15+

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/a2a-swift", from: "1.0.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: ["A2A"]),
]
```

---

## Client SDK

### Basic usage

```swift
import A2A

let client = A2AClient(url: "https://agent.example.com")

// Send a message and get back a Task or Message
let response = try await client.sendMessage(
    SendMessageRequest.with {
        $0.message = Message.with {
            $0.messageID = UUID().uuidString
            $0.role = .user
            $0.parts = [Part.with { $0.text = "Hello!" }]
        }
    }
)

switch response.result {
case .task(let task):
    print("Task created:", task.id)
case .message(let msg):
    print("Direct reply:", msg.parts.first?.text ?? "")
default:
    break
}
```

### Streaming

```swift
let stream = client.sendMessageStream(
    SendMessageRequest.with { /* ... */ }
)

for try await event in stream {
    switch event.result {
    case .statusUpdate(let e):
        print("State:", e.status.state)
    case .artifactUpdate(let e):
        print("Artifact:", e.artifact.name)
    default:
        break
    }
}
```

### Task management

```swift
// Get task status
let task = try await client.getTask(
    GetTaskRequest.with { $0.taskID = "task-id" }
)

// Cancel a task
let canceled = try await client.cancelTask(
    CancelTaskRequest.with { $0.taskID = "task-id" }
)

// List tasks
let list = try await client.listTasks(ListTasksRequest())

// Subscribe to a running task
let events = client.subscribeToTask(
    SubscribeToTaskRequest.with { $0.taskID = "task-id" }
)
```

### Agent card

```swift
// Fetch the public agent card
let card = try await client.getAgentCard()

// Fetch the authenticated extended card (if supported)
let extCard = try await client.getExtendedAgentCard(
    GetExtendedAgentCardRequest()
)
```

---

## Transport & Protocol Negotiation

`A2ATransportFactory` automatically picks the best transport by reading the
`supportedInterfaces` field of the agent card.

| Protocol Binding | Transport |
|---|---|
| `JSON_RPC` (default) | `SseTransport` — JSON-RPC 2.0 over HTTP + SSE |
| `HTTP_JSON` | `RestTransport` — RESTful HTTP without JSON-RPC envelopes |
| `JSON_RPC` with `protocolVersion: "0.3"` | `V0JSONRPCTransport` — backward-compat v0.3 |

```swift
// Factory auto-selects based on the agent card
let factory = A2ATransportFactory()
let client = A2AClient(url: "https://agent.example.com", transportFactory: factory)

// Or pin a specific transport
let transport = V0JSONRPCTransport(url: "https://legacy-agent.example.com")
let legacyClient = A2AClient(url: "https://legacy-agent.example.com", transport: transport)
```

### Multi-tenant

```swift
// Attach a tenant ID to all requests in a Task scope
await TenantID.$current.withValue("tenant-abc") {
    let response = try await client.sendMessage(...)
}

// Or use TenantTransportDecorator for automatic per-request base URL rewriting
let tenantTransport = TenantTransportDecorator(
    inner: SseTransport(url: "https://agent.example.com"),
    baseURLOverrides: ["tenant-abc": "https://tenant-abc.agent.example.com"]
)
```

---

## Middleware (Handlers)

Handlers intercept every request/response cycle. Chain them by passing an array to `A2AClient`.

### Built-in handlers

```swift
let client = A2AClient(
    url: "https://agent.example.com",
    handlers: [
        LoggingHandler(level: .debug, logPayloads: true),
        AuthHandler(credentialsService: myCredentialStore),
        ExtensionActivator(extensionURIs:
            "https://a2aprotocol.ai/extensions/thinking/v1"
        ),
    ]
)
```

### Custom handler

Extend `PassthroughContextualHandler` and override only the methods you need:

```swift
class RetryHandler: PassthroughContextualHandler {
    override func beforeRequest(_ request: inout A2ARequest) async throws {
        // Inject a custom header
        request.serviceParams.append("x-request-id", [UUID().uuidString])
    }

    override func afterResponse(_ response: inout A2AResponse) async throws {
        // Log every response
        print("RPC result for", response.method)
    }
}
```

---

## Authentication

```swift
// In-memory credential store keyed by session ID
let store = InMemoryCredentialsStore()
await store.set(
    AuthCredential(scheme: "Bearer", token: "my-token"),
    for: "session-123"
)

let client = A2AClient(
    url: "https://agent.example.com",
    handlers: [AuthHandler(credentialsService: store)]
)

// Attach a session ID to the current Task so AuthHandler picks up the credential
await SessionID.$current.withValue("session-123") {
    let response = try await client.sendMessage(...)
}
```

---

## Agent Card Resolver

Customise where and how the agent card is fetched:

```swift
let resolver = AgentCardResolver(url: "https://agent.example.com")
    .withPath("/.well-known/my-custom-agent.json")
    .withRequestHeader("Authorization", "Bearer my-token")

let client = A2AClient(url: "https://agent.example.com", cardResolver: resolver)
```

---

## Server SDK

Implement the `AgentExecutor` protocol and wire it to `A2AServer`:

```swift
import A2A

// 1. Implement your agent logic
struct EchoExecutor: AgentExecutor {
    func execute(context: ExecutorContext) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            var status = TaskStatusUpdateEvent()
            status.taskID = context.taskID
            status.status = TaskStatus.with { $0.state = .working }
            continuation.yield(.statusUpdate(status))

            var done = TaskStatusUpdateEvent()
            done.taskID = context.taskID
            done.status = TaskStatus.with {
                $0.state = .completed
                $0.message = context.message   // echo the input back
            }
            continuation.yield(.statusUpdate(done))
            continuation.finish()
        }
    }

    func cancel(context: ExecutorContext) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            var ev = TaskStatusUpdateEvent()
            ev.taskID = context.taskID
            ev.status = TaskStatus.with { $0.state = .canceled }
            continuation.yield(.statusUpdate(ev))
            continuation.finish()
        }
    }
}

// 2. Build the server
let agentCard = AgentCard.with {
    $0.name = "Echo Agent"
    $0.description_p = "Echoes your message back"
    $0.version = "1.0.0"
    $0.capabilities = AgentCapabilities.with { $0.streaming = true }
}

let server = A2AServer(
    handler: DefaultRequestHandler(executor: EchoExecutor()),
    agentCard: agentCard
)

// 3. Dispatch requests from your HTTP framework
// (Vapor, Hummingbird, NIO, or a plain URLSession in tests)
let req = ServerRequest(
    method: "GET",
    path: "/.well-known/agent.json"
)
let result = await server.handle(req)
// → .response with Content-Type: application/json and agent card body
```

### Request handler options

```swift
let options = A2ARequestHandlerOptions(
    taskStore: MyCustomTaskStore(),          // default: InMemoryTaskStore
    pushConfigStore: InMemoryPushConfigStore(),
    pushSender: HTTPPushSender(),            // sends HTTP POST for push notifications
    capabilities: AgentCapabilities.with {
        $0.streaming = true
        $0.pushNotifications = true
        $0.extendedAgentCard = true
    },
    extendedCardProducer: {
        // Return a richer card for authenticated clients
        return myExtendedCard
    }
)

let handler = DefaultRequestHandler(executor: EchoExecutor(), options: options)
```

### Supported JSON-RPC methods

| Method | Handler call |
|---|---|
| `message/send` | `sendMessage` |
| `message/stream` | `sendStreamingMessage` (SSE) |
| `tasks/get` | `getTask` |
| `tasks/list` | `listTasks` |
| `tasks/cancel` | `cancelTask` |
| `tasks/resubscribe` | `subscribeToTask` (SSE) |
| `tasks/pushNotificationConfig/set` | `createTaskPushConfig` |
| `tasks/pushNotificationConfig/get` | `getTaskPushConfig` |
| `tasks/pushNotificationConfig/list` | `listTaskPushConfigs` |
| `tasks/pushNotificationConfig/delete` | `deleteTaskPushConfig` |
| `agent/authenticatedExtendedCard` | `getExtendedAgentCard` |

---

## v0.3 Compatibility

To talk to a legacy A2A v0.3 server, use `V0JSONRPCTransport`:

```swift
let transport = V0JSONRPCTransport(url: "https://legacy-agent.example.com")
let client = A2AClient(url: "https://legacy-agent.example.com", transport: transport)
```

`V0JSONRPCTransport` transparently handles:

- Method name mapping (`agent/authenticatedExtendedCard` ↔ `agent/getAuthenticatedExtendedCard`)
- Parameter shape differences (`taskId` vs `id`, `blocking` vs `returnImmediately`)
- Header remapping (`A2A-Extensions` ↔ `X-A2A-Extensions`)
- Agent card normalisation (flat v0.3 fields → v1.0 `supportedInterfaces`)
- `tasks/list` is rejected (unsupported in v0.3)

`A2ATransportFactory` selects this transport automatically when the agent card's `supportedInterfaces` contains a `protocolVersion` of `"0.3"`.

---

## Protocol Extensions

Use `ExtensionActivator` on the client to opt into A2A protocol extensions:

```swift
let client = A2AClient(
    url: "https://agent.example.com",
    handlers: [
        ExtensionActivator(extensionURIs:
            "https://a2aprotocol.ai/extensions/thinking/v1"
        )
    ]
)
```

On the server, use `ServerExtensionPropagator` to extract activated extensions from an incoming request:

```swift
let propagator = ServerExtensionPropagator()
let activeExtensions = propagator.extract(from: serviceParams)
```

---

## Error Handling

All transport errors are typed as `A2ATransportError`:

```swift
do {
    let response = try await client.sendMessage(...)
} catch A2ATransportError.taskNotFound(let msg) {
    print("Task not found:", msg)
} catch A2ATransportError.unauthenticated(let msg) {
    print("Auth required:", msg)
} catch A2ATransportError.versionNotSupported(let msg) {
    print("Protocol version mismatch:", msg)
}
```

| Case | JSON-RPC Code | HTTP Status |
|---|---|---|
| `.taskNotFound` | -32001 | — |
| `.taskNotCancelable` | -32002 | — |
| `.pushNotificationNotSupported` | -32003 | — |
| `.unsupportedOperation` | -32004 | — |
| `.unsupportedContentType` | -32005 | 415 |
| `.invalidAgentResponse` | -32006 | — |
| `.pushNotificationConfigNotFound` | -32007 | — |
| `.extensionSupportRequired` | -32008 | — |
| `.versionNotSupported` | -32009 | — |
| `.unauthenticated` | -31401 | 401 |
| `.unauthorized` | -31403 | 403 |

---

## License

Apache 2.0 — see [LICENSE](LICENSE).
