# Swift A2A SDK — Gap TODO

> 对齐目标：与 Go SDK (`a2aclient/`) 功能对等。
> 按优先级从小到大排列，前面的任务不依赖后面的。

---

## 第一阶段：方法补齐（最小改动）

- [x] **ListTasks** — `listTasks(_:)` 已实现（A2AClient.swift:417）
- [x] **UpdateCard** — `updateCard(_:)` 已实现（A2AClient.swift:165）
- [x] **Destroy / close** — `close()` 已实现（A2AClient.swift:573）

---

## 第二阶段：错误类型补齐

- [x] 在 `A2ATransportError` 中添加缺失的 case：
  - [x] `.versionNotSupported(message:)` — 协议版本不兼容（JSON-RPC -32009）
  - [x] `.extensionSupportRequired(message:)` — 需要 extension 支持（JSON-RPC -32008）
  - [x] `.unauthenticated(message:)` — HTTP 401（JSON-RPC -31401）
  - [x] `.unauthorized(message:)` — HTTP 403（JSON-RPC -31403）
  - [x] `.unsupportedContentType(message:)` — HTTP 415（JSON-RPC -32005）
  - [x] `.invalidAgentResponse(message:)` — Agent 返回格式错误（JSON-RPC -32006）
  - 同步修正 `transportError(from:)` 中已有错误的码映射（-32003/-32006/-32007）

---

## 第三阶段：Middleware / Interceptor 增强

- [x] **丰富的 CallInterceptor 上下文** — 定义 `A2ARequest` / `A2AResponse` 类型（携带 `method`、`card`、`payload`、`serviceParams`），让 handler 能访问完整上下文，而不只是裸 `[String: Any]`
- [x] **PassthroughHandler** — 提供默认 no-op 实现，handler 只需 override 关心的方法
- [x] **LoggingHandler** — 内置日志 handler，支持 level / logPayload 配置，对应 Go `NewLoggingInterceptor`

---

## 第四阶段：ServiceParams

- [x] 定义 `ServiceParams` 类型 — case-insensitive 的 `[String: [String]]` 映射，支持 `get(_:)` / `append(_:_:)` 方法，对应 Go `a2aclient.ServiceParams`
- [x] 将 `A2AClient` 中现有的 `[String: String]` headers 替换为 `ServiceParams`
- [x] 在 `A2ATransport` 协议中传递 `ServiceParams`

---

## 第五阶段：认证体系

- [x] **CredentialsService 协议** — 按 SessionID 存取 `AuthCredential` 的接口
- [x] **InMemoryCredentialsStore** — `CredentialsService` 的内存实现
- [x] **SessionID** — 定义 SessionID 类型及 Task-local 存取 API（对应 Go 的 `AttachSessionID` / `SessionIDFrom`）
- [x] **AuthHandler** — 基于 `CredentialsService` 的通用认证 handler（对应 Go `AuthInterceptor`）

---

## 第六阶段：AgentCard Resolver

- [x] 将 AgentCard 解析逻辑抽离为独立 `AgentCardResolver` 类型，支持：
  - [x] `withPath(_:)` — 自定义 well-known path
  - [x] `withRequestHeader(_:_:)` — 解析请求时附加 header
- [x] `A2AClient` 改为通过 `AgentCardResolver` 获取 card

---

## 第七阶段：传输层扩展

- [x] **REST Transport** — 实现基于 REST（非 JSON-RPC）的 `A2ATransport`
- [x] **Factory + 传输协商** — 读取 AgentCard 中的协议版本，自动选择 JSON-RPC / REST transport
- [x] **多租户 TransportDecorator** — 支持按租户替换 baseURL（对应 Go `tenantTransportDecorator`）
- [ ] **gRPC Transport** — 基于 gRPC 的 `A2ATransport` 实现（工作量最大，可选）

---

## 第八阶段：服务端 SDK

- [x] **AgentExecutor 协议** — 定义服务端 agent 执行接口（对应 Go `a2asrv.AgentExecutor`）
- [x] **A2AServer** — HTTP server，负责路由、AgentCard 托管、JSON-RPC dispatch
- [x] **TaskManager** — 任务生命周期管理（状态机、推送通知）
- [x] **Push Notification Server** — 服务端推送实现

---

## 第九阶段：其他

- [x] **兼容层** — 支持旧版 A2A 协议（对应 Go `a2acompat/a2av0/`）
- [x] **扩展支持** — `a2aext/` 协议扩展机制
- [ ] **CLI 工具** — 不做（Swift SDK 不需要命令行工具）
