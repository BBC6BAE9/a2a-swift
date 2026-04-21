# A2A Swift SDK — Complete Codebase Summary

**Date**: 2026-04-21  
**Project**: Swift A2A (Agent-to-Agent) Client SDK  
**Status**: Phase 7 Complete (Transport Layer Extensions)  
**Repository**: `/Users/hong/Desktop/a2a/a2a-swift`

---

## 📋 Directory Structure

```
Sources/A2A/
├── Client/                          # Main client implementation
│   ├── A2AClient.swift              # Main client class (790 lines)
│   ├── A2ATransport.swift           # Transport protocol
│   ├── A2ATransportError.swift      # Error types
│   ├── A2AHandler.swift             # Middleware/interceptor protocol
│   ├── A2AContextualHandler.swift   # Enhanced contextual handlers
│   ├── PassthroughHandler.swift     # No-op base handler
│   ├── LoggingHandler.swift         # Built-in logging middleware
│   ├── AuthHandler.swift            # Authentication middleware
│   ├── SessionID.swift              # Task-local session tracking
│   ├── CredentialsService.swift     # Auth credential storage interface
│   ├── ServiceParams.swift          # Multi-value header/param map
│   ├── AgentCardResolver.swift      # Card fetching with customization
│   ├── HttpTransport.swift          # HTTP transport implementation
│   ├── SseTransport.swift           # SSE streaming transport
│   ├── RestTransport.swift          # REST/non-JSON-RPC transport
│   ├── A2ATransportFactory.swift    # Transport selection logic
│   ├── TenantTransportDecorator.swift # Tenant injection decorator
│   ├── TenantID.swift               # Task-local tenant tracking
│   └── SseParser.swift              # Server-Sent Events parser
└── Generated/
    └── a2a.pb.swift                 # Protobuf message definitions

Tests/A2ATests/
└── Fakes.swift                      # Test doubles (TestTransport, TestHandler)
```

---

## 🏗️ Core Architecture

### 1. **A2ATransport Protocol** (Network abstraction)
- `get(path:params:)` → Fetch resource via HTTP GET
- `send(_:path:params:)` → Single JSON-RPC request/response
- `sendStream(_:params:)` → Streaming JSON-RPC (SSE)
- `close()` → Graceful shutdown
- `authParams` → Per-transport auth headers

**Implementations**:
- **HttpTransport**: Standard HTTP GET/POST (JSON-RPC only)
- **SseTransport**: Extends HttpTransport with SSE streaming support
- **RestTransport**: Non-JSON-RPC REST-style endpoints
- **TenantTransportDecorator**: Wraps any transport to inject tenant ID

### 2. **A2AClient** (Main entry point)
**Key features**:
- Sends JSON-RPC 2.0 requests to A2A servers
- Auto-increments request IDs (thread-safe via NSLock)
- Manages cached AgentCard for capability-gating
- Handler pipeline for request/response interception
- Fallback from streaming to single-shot when card says no streaming
- 20+ methods covering all A2A spec operations

**Method categories**:
- **Card management**: `getAgentCard()`, `getAuthenticatedExtendedCard()`, `getExtendedAgentCard()`
- **Messaging**: `messageSend()`, `messageStream()` with config defaults
- **Tasks**: `getTask()`, `listTasks()`, `cancelTask()`, `subscribeToTask()`
- **Push notifications**: Set/get/list/delete push notification configs
- **Lifecycle**: `updateCard()`, `close()`

### 3. **Handler Pipeline** (Middleware system)
**Flow**:
```
Request:  [Handler₁ → Handler₂ → Handler₃ → Transport]
Response: [Handler₃ → Handler₂ → Handler₁ → Caller]
```

**Features**:
- **Early return**: Handler can short-circuit transport by setting `_a2a_early_response`
- **Service params injection**: Handlers embed `_a2a_service_params` to inject auth headers
- **Contextual dispatch**: Pipeline checks for `A2AContextualHandler` and passes structured context

**Built-in handlers**:
- **PassthroughHandler**: No-op base; override what you need
- **PassthroughContextualHandler**: Contextual version of above
- **LoggingHandler**: Configurable structured logging with payload/timing
- **AuthHandler**: Reads `SessionID` + `CredentialsService` → injects auth headers

### 4. **Authentication System**
**Components**:
- **SessionID** (@TaskLocal): Per-task session identifier
- **CredentialsService** (protocol): Get credentials by session + scheme
- **InMemoryCredentialsStore**: Thread-safe in-memory implementation
- **AuthHandler**: Auto-injects credentials based on AgentCard security requirements

**Usage**:
```swift
let store = InMemoryCredentialsStore()
store.set("session-1", scheme: "bearerAuth", credential: "my-token")

let client = A2AClient(
    url: "http://localhost:8000",
    handlers: [AuthHandler(credentialsService: store)]
)

await SessionID.$current.withValue("session-1") {
    let response = try await client.messageSend(myMessage)
    // → Authorization: Bearer my-token is injected automatically
}
```

### 5. **Transport Selection** (A2ATransportFactory)
**Selection rules**:
1. Filter `AgentCard.supportedInterfaces` by known protocol bindings
2. Sort by: protocol version (semver, newer first) → binding preference (JSON-RPC > REST)
3. Select first candidate; map to HttpTransport/SseTransport/RestTransport
4. Wrap in TenantTransportDecorator for tenant propagation
5. Fallback to SseTransport(baseURL) if no interface found

**Protocol bindings**:
- `"JSON_RPC"` → HttpTransport / SseTransport
- `"HTTP_JSON"` → RestTransport

### 6. **Tenant Propagation** (TenantTransportDecorator)
**Priority**:
1. Tenant already in `params.tenant` → use it
2. Static `tenant` field set on decorator → use it
3. `TenantID.current` task-local → use it
4. If no tenant → forward request unchanged

**Usage**:
```swift
await TenantID.$current.withValue("acme-corp") {
    let response = try await client.messageSend(message)
    // → request["params"]["tenant"] = "acme-corp" injected automatically
}
```

### 7. **ServiceParams** (Multi-value header map)
- Case-insensitive key lookup
- Supports multi-value entries (e.g., `Accept: application/json, text/html`)
- Deduplicates on append
- Methods: `get(_:)`, `append(_:_:)`, `asDictionary()`, `asHTTPHeaders()`

### 8. **AgentCardResolver** (Card fetching)
**Features**:
- Builder API: `withPath()`, `withRequestHeader()`
- Fetch from custom URL + path
- Include auth headers in fetch request
- Auto-decode JSON to `AgentCard` protobuf

---

## 📊 Error Handling (A2ATransportError)

**JSON-RPC errors** (mapped by code):
- `-32001` → `.taskNotFound(message:)`
- `-32002` → `.taskNotCancelable(message:)`
- `-32003` → `.pushNotificationNotSupported(message:)` (code -32003)
- `-32004` → `.unsupportedOperation(message:)`
- `-32005` → `.unsupportedContentType(message:)`
- `-32006` → `.invalidAgentResponse(message:)`
- `-32007` → `.extendedCardNotConfigured`
- `-32008` → `.extensionSupportRequired(message:)`
- `-32009` → `.versionNotSupported(message:)`
- `-31401` → `.unauthenticated(message:)` (HTTP 401)
- `-31403` → `.unauthorized(message:)` (HTTP 403)

**Transport errors**:
- `.jsonRpc(code:message:)` → Generic JSON-RPC error
- `.http(statusCode:reason:)` → Non-2xx HTTP status
- `.network(message:)` → Connection/DNS issues
- `.parsing(message:)` → JSON/proto decode error
- `.unsupportedOperation(message:)` → Feature not available on transport

---

## 🔄 Request/Response Flow

### Example: `messageSend(_:)`

```
1. A2AClient.messageSend(message)
2. Build SendMessageRequest (apply config defaults)
3. Encode to JSON-RPC params
4. Build JSON-RPC request envelope with auto-increment ID
5. → applyRequestHandlers()
   - Iterate handlers in order
   - Each handler can modify request or set early response
   - Accumulate service params from handlers
6. Merge handler params + caller params → finalParams
7. → transport.send(processed, params: finalParams)
8. ← parseJSON response
9. → applyResponseHandlers()
   - Iterate handlers in REVERSE order
   - Each handler can modify response
10. ← Decode response["result"] → SendMessageResponse
```

---

## 📝 File Manifest

| File | Lines | Description |
|------|-------|-------------|
| A2AClient.swift | 790 | Main client + JSON-RPC/proto encoding helpers |
| A2ATransport.swift | 112 | Protocol + convenience overloads |
| A2ATransportError.swift | 172 | Comprehensive error enum |
| A2AHandler.swift | 230 | Protocol + pipeline implementation |
| A2AContextualHandler.swift | 219 | Structured context types + handlers |
| PassthroughHandler.swift | 60 | No-op base implementation |
| LoggingHandler.swift | 187 | Structured logging with timing |
| AuthHandler.swift | 149 | Session/credentials-based auth injection |
| SessionID.swift | 54 | Task-local session identifier |
| CredentialsService.swift | 140 | Auth credential storage protocol + in-memory store |
| ServiceParams.swift | 148 | Multi-value header/param map |
| AgentCardResolver.swift | 147 | Card fetching with builder API |
| HttpTransport.swift | 217 | HTTP GET/POST (JSON-RPC) |
| SseTransport.swift | 178 | SSE streaming (extends HttpTransport) |
| RestTransport.swift | 505 | REST/non-JSON-RPC endpoint mapping |
| A2ATransportFactory.swift | 179 | Transport selection + SemVer logic |
| TenantTransportDecorator.swift | 133 | Tenant injection decorator |
| TenantID.swift | 47 | Task-local tenant identifier |
| SseParser.swift | 150 | SSE event parsing + JSON-RPC envelope extraction |
| Fakes.swift | 170 | TestTransport + TestHandler test doubles |
| **Total** | **~4,000** | **Complete client SDK** |

---

## 🎯 Phases Completed

| Phase | Status | Deliverables |
|-------|--------|--------------|
| 1: Method Alignment | ✅ | `listTasks()`, `updateCard()`, `close()` |
| 2: Error Types | ✅ | 11 new error cases + code mappings |
| 3: Middleware | ✅ | Contextual handlers + PassthroughHandler + LoggingHandler |
| 4: ServiceParams | ✅ | Multi-value map type + integration |
| 5: Auth System | ✅ | SessionID + CredentialsService + AuthHandler |
| 6: AgentCardResolver | ✅ | Custom path + headers builder API |
| 7: Transport Extensions | ✅ | RestTransport + Factory + TenantTransportDecorator |
| 8: Server SDK | ❌ | Not started (out of scope) |
| 9: Other | ❌ | Not started |

---

## 🧪 Test Infrastructure

**Fakes.swift** provides:
- **TestTransport**: Configurable mock with captured call args + closure-based responses
- **TestHandler**: Captures last request/response + optional closure overrides
- **Helpers**: `drainStream()`, `makeStream()`, `makeErrorStream()`

---

## 📚 Key Patterns

1. **Sendable + @unchecked Sendable**: Thread-safe types; NSLock for internal state
2. **Extension overloads**: Default parameters reduce boilerplate
3. **Builder API**: AgentCardResolver + A2ATransportFactory
4. **Protocol composition**: A2AHandler + A2AContextualHandler + PassthroughHandler hierarchy
5. **Task-local storage**: `@TaskLocal` for SessionID / TenantID propagation
6. **Protobuf bridging**: `encodeProto()` / `decodeProto()` for type-safe JSON-RPC params
7. **Early return pattern**: Handlers can set `_a2a_early_response` key to skip transport

---

## 🔗 Go SDK Alignment

This Swift SDK mirrors the Go client (`a2aclient/` package) across:
- JSON-RPC 2.0 protocol conformance
- Error code mappings
- Handler/interceptor architecture
- Auth + credentials system
- Transport abstraction + factory
- Tenant propagation
- Service params (multi-value headers)
- SSE parsing logic
- REST endpoint mapping

---

## ✨ Highlights

✅ **Full Go parity** for client-side operations  
✅ **Type-safe** Protobuf message handling  
✅ **Streaming support** via SSE  
✅ **Pluggable auth** with SessionID + CredentialsService  
✅ **Handler middleware** with early-return & context passing  
✅ **Multi-transport** (JSON-RPC, REST, SSE)  
✅ **Tenant propagation** via decorator  
✅ **Structured logging** with payload toggle  
✅ **Comprehensive error types** with proper mapping  
✅ **Test-friendly** with configurable fakes  

