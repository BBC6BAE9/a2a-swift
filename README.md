# A2A Swift SDK

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS-blue.svg)](Package.swift)

<!-- markdownlint-disable no-inline-html -->

<div align="center">
   <img src="https://raw.githubusercontent.com/a2aproject/A2A/refs/heads/main/docs/assets/a2a-logo-black.svg" width="256" alt="A2A Logo"/>
   <h3>
      A Swift library for building and consuming agentic applications following the <a href="https://a2a-protocol.org">Agent2Agent (A2A) Protocol</a>.
   </h3>
</div>

<!-- markdownlint-enable no-inline-html -->

---

## ✨ Features

- **A2A Protocol Compliance:** Build agentic applications that adhere to the Agent2Agent (A2A) **v1.0 Protocol Specification**.
- **Client & Server SDKs:** High-level APIs for both serving agentic functionality (`A2AServer`) and consuming it (`A2AClient`).
- **Multi-Transport Support:** Protocol bindings for REST and JSON-RPC over SSE, with automatic transport negotiation.
- **Extensible & Pluggable:** Extension points for custom transports, authentication middleware, and task store backends.
- **v0.3 Compatibility:** Transparent backward-compatibility layer for legacy A2A v0.3 servers.

> **Note:** The SDK version is distinct from the A2A specification version. The supported protocol version is `1.0`.

---

## 🚀 Getting Started

Requires **Swift 5.9+**, **Xcode 15+**, and one of:
iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / visionOS 1

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/BBC6BAE9/a2a-swift", from: "1.0.0"),
],
targets: [
    // Client only
    .target(name: "YourTarget", dependencies: ["A2AClient"]),

    // Server only
    .target(name: "YourTarget", dependencies: ["A2AServer"]),

    // Both
    .target(name: "YourTarget", dependencies: ["A2AClient", "A2AServer"]),
]
```

## 💡 Examples

### Server

1. Implement your agent logic by conforming to `AgentExecutor`:

    ```swift
    import A2AServer
    import A2ACore

    struct EchoExecutor: AgentExecutor {
        func execute(context: ExecutorContext) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { continuation in
                var done = TaskStatusUpdateEvent()
                done.taskID = context.taskID
                done.status = TaskStatus.with {
                    $0.state = .completed
                    $0.message = context.message
                }
                continuation.yield(.statusUpdate(done))
                continuation.finish()
            }
        }
    }
    ```

2. Build the request handler and server:

    ```swift
    let agentCard = AgentCard.with {
        $0.name = "Echo Agent"
        $0.description_p = "Echoes your message back"
        $0.version = "1.0.0"
        $0.capabilities = AgentCapabilities.with { $0.streaming = true }
    }

    let handler = DefaultRequestHandler(executor: EchoExecutor())
    let server = A2AServer(handler: handler, agentCard: agentCard)
    ```

3. Dispatch requests from your HTTP framework (Vapor, Hummingbird, etc.):

    ```swift
    let req = ServerRequest(method: method, path: path, body: body, headers: headers)
    let result = await server.handle(req)
    // Write result.statusCode / result.headers / result.body to your response
    ```

### Client

1. Resolve an `AgentCard` to discover how an agent is exposed:

    ```swift
    import A2AClient

    let resolver = AgentCardResolver(url: "https://agent.example.com")
    let card = try await resolver.resolve()
    ```

2. Create a client — transport is negotiated automatically from the card:

    ```swift
    let client = A2AClient(url: "https://agent.example.com")
    ```

3. Send requests:

    ```swift
    import A2ACore

    let msg = A2ACore.Message.with {
        $0.messageID = UUID().uuidString
        $0.role = .user
        $0.parts = [Part.with { $0.text = TextPart.with { $0.text = "Hello!" } }]
    }

    let response = try await client.messageSend(msg)
    ```

4. Or stream responses over SSE:

    ```swift
    for try await event in client.messageStream(msg) {
        switch event.result {
        case .statusUpdate(let e): print("State:", e.status.state)
        case .artifactUpdate(let e): print("Artifact:", e.artifact.name)
        default: break
        }
    }
    ```

---

## 🔧 Middleware (Handlers)

Chain handlers to intercept every request/response cycle:

```swift
let client = A2AClient(
    url: "https://agent.example.com",
    handlers: [
        LoggingHandler(level: .debug),
        AuthHandler(credentialsService: myCredentialStore),
        ExtensionActivator(extensionURIs:
            "https://a2aprotocol.ai/extensions/thinking/v1"
        ),
    ]
)
```

Implement your own by extending `PassthroughContextualHandler`:

```swift
class RetryHandler: PassthroughContextualHandler {
    override func handleRequest(_ request: A2ARequest) async throws -> [String: Any] {
        // Modify or log before sending
        return try await next(request)
    }
}
```

---

## 🌐 More Examples

You can find more detailed examples in the [a2a-samples](https://github.com/a2aproject/a2a-samples) repository.

---

## 🤝 Contributing

Contributions are welcome! Please open an issue to discuss your proposed approach before starting work on a new feature or significant change.

---

## 📄 License

This project is licensed under the Apache 2.0 License. See the [LICENSE](LICENSE) file for more details.
