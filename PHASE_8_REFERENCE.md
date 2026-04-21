# Phase 8: Swift Server SDK — Go Reference Implementation Guide

## Overview
This document maps Go A2A Server SDK (`a2a-go/a2asrv/`) components to their Swift equivalents for Phase 8 implementation.

---

## 1. AgentExecutor Protocol

### Go Definition (a2asrv/agentexec.go:95-120)
```go
type AgentExecutor interface {
    // Execute invokes the agent, translates outputs to A2A events
    Execute(ctx context.Context, execCtx *ExecutorContext) iter.Seq2[a2a.Event, error]
    
    // Cancel stops agent work on a task (with OCC retry logic)
    Cancel(ctx context.Context, execCtx *ExecutorContext) iter.Seq2[a2a.Event, error]
}

type AgentExecutionCleaner interface {
    Cleanup(ctx context.Context, execCtx *ExecutorContext, result a2a.SendMessageResult, err error)
}
```

### Swift Equivalent
```swift
// Sources/A2A/Server/AgentExecutor.swift

protocol AgentExecutor: AnyObject {
    /// Execute invokes the agent, translates outputs to A2A events.
    /// Returns an AsyncSequence emitting Events and errors.
    func execute(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error>
    
    /// Cancel stops agent work on a task (with OCC retry logic up to 10 times).
    /// Returns an AsyncSequence emitting cancel events.
    func cancel(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error>
}

protocol AgentExecutionCleaner: AnyObject {
    /// Called after execution completes with result or error.
    func cleanup(context: ExecutorContext, result: SendMessageResult, error: Error?) async
}

// Conforming types can implement both AgentExecutor and AgentExecutionCleaner
extension MyAgent: AgentExecutor, AgentExecutionCleaner {
    func execute(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error> {
        // Return async sequence via AsyncStream
    }
    
    func cancel(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error> {
        // Return async sequence for cancel events
    }
    
    func cleanup(context: ExecutorContext, result: SendMessageResult, error: Error?) async {
        // Cleanup resources
    }
}
```

### Key Implementation Notes
- **Streaming Template:** Use AsyncStream builder pattern
- **Event Emission Rules:**
  - First event: Message or Task
  - Subsequent: TaskStatusUpdateEvent or TaskArtifactUpdateEvent
  - Termination: Message, Terminal state, or INPUT_REQUIRED state
- **Error Handling:** Report via events (TaskStatusUpdateEvent with failed state), not exceptions (except pre-task creation)
- **Cancel Retry:** OCC logic auto-retries up to 10 times on concurrent modifications

---

## 2. ExecutorContext

### Go Definition (a2asrv/exectx.go:40-103)
```go
type ExecutorContext struct {
    Message     *a2a.Message
    TaskID      a2a.TaskID
    StoredTask  *taskstore.StoredTask  // nil on first execution
    RelatedTasks *[]*a2a.Task          // optional
    ContextID   a2a.ContextID
    Metadata    map[string]any
    User        *a2a.User
    ServiceParams a2aclient.ServiceParams
    Tenant      string
    // Private ctx field for context chain
}

// Implements TaskInfoProvider
func (ec *ExecutorContext) TaskInfo() a2a.TaskInfo {
    return a2a.TaskInfo{TaskID: ec.TaskID, ContextID: ec.ContextID}
}
```

### Swift Equivalent
```swift
// Sources/A2A/Server/ExecutorContext.swift

class ExecutorContext {
    let message: Message?
    let taskID: TaskID
    let storedTask: StoredTask?  // nil on first execution
    let relatedTasks: [Task]?
    let contextID: ContextID
    let metadata: [String: AnyCodable]
    var user: User?
    var serviceParams: ServiceParams
    var tenant: String?
    
    // Internal context for chaining
    private let underlyingContext: _ExecutorContextValue
    
    init(message: Message?, 
         taskID: TaskID, 
         storedTask: StoredTask? = nil,
         relatedTasks: [Task]? = nil,
         contextID: ContextID,
         metadata: [String: AnyCodable] = [:]) {
        self.message = message
        self.taskID = taskID
        self.storedTask = storedTask
        self.relatedTasks = relatedTasks
        self.contextID = contextID
        self.metadata = metadata
        self.underlyingContext = _ExecutorContextValue(taskID: taskID, contextID: contextID)
    }
}

// Implements TaskInfoProvider
extension ExecutorContext: TaskInfoProvider {
    func taskInfo() -> TaskInfo {
        TaskInfo(taskID: taskID, contextID: contextID)
    }
}

// Task-local storage for context
enum ExecutorContextKey: TaskLocalKey {
    typealias Value = ExecutorContext
}

// Access: ExecutorContext.current
extension ExecutorContext {
    @TaskLocal static var current: ExecutorContext?
}
```

### Key Components
| Go | Swift | Purpose |
|---|---|---|
| `Message *a2a.Message` | `message: Message?` | Original message that triggered execution |
| `TaskID a2a.TaskID` | `taskID: TaskID` | Unique task identifier |
| `StoredTask *taskstore.StoredTask` | `storedTask: StoredTask?` | Previous task state with version (nil on first) |
| `RelatedTasks *[]*a2a.Task` | `relatedTasks: [Task]?` | Referenced tasks (lazy-loaded) |
| `ContextID a2a.ContextID` | `contextID: ContextID` | Conversation context ID |
| `Metadata map[string]any` | `metadata: [String: AnyCodable]` | Custom metadata |
| `User *a2a.User` | `user: User?` | Authenticated user |
| `ServiceParams` | `serviceParams: ServiceParams` | HTTP headers as key-value pairs |
| `Tenant string` | `tenant: String?` | Multi-tenancy support |

---

## 3. TaskStore Protocol & OCC

### Go Definition (a2asrv/taskstore/api.go)
```go
type TaskVersion int64
var TaskVersionMissing TaskVersion = 0

func (v TaskVersion) After(another TaskVersion) bool {
    if another == TaskVersionMissing {
        return true
    }
    if v == TaskVersionMissing {
        return false
    }
    return another < v
}

type StoredTask struct {
    Task    *a2a.Task
    Version TaskVersion
}

type UpdateRequest struct {
    Task        *a2a.Task
    Event       a2a.Event
    PrevVersion TaskVersion
}

type Store interface {
    Create(ctx context.Context, task *a2a.Task) (TaskVersion, error)
    Update(ctx context.Context, update *UpdateRequest) (TaskVersion, error)
    Get(ctx context.Context, taskID a2a.TaskID) (*StoredTask, error)
    List(ctx context.Context, req *a2a.ListTasksRequest) (*a2a.ListTasksResponse, error)
}

var ErrConcurrentModification = errors.New("concurrent modification")
var ErrTaskAlreadyExists = errors.New("task already exists")
```

### Swift Equivalent
```swift
// Sources/A2A/Server/TaskStore.swift

typealias TaskVersion = Int64
let taskVersionMissing: TaskVersion = 0

extension TaskVersion {
    /// Returns true if this version is newer than another.
    /// Treats TaskVersionMissing as "latest" (always true).
    func after(_ other: TaskVersion) -> Bool {
        if other == taskVersionMissing {
            return true
        }
        if self == taskVersionMissing {
            return false
        }
        return other < self
    }
}

struct StoredTask {
    let task: Task
    let version: TaskVersion
}

struct UpdateRequest {
    let task: Task
    let event: Event
    let prevVersion: TaskVersion
}

protocol TaskStore: AnyObject {
    /// Create a new task. Returns ErrTaskAlreadyExists if exists.
    func create(task: Task) async throws -> TaskVersion
    
    /// Update task with version checking (OCC). Returns ErrConcurrentModification on conflict.
    func update(request: UpdateRequest) async throws -> TaskVersion
    
    /// Get task by ID. Returns ErrTaskNotFound if missing.
    func get(taskID: TaskID) async throws -> StoredTask
    
    /// List tasks by criteria.
    func list(request: ListTasksRequest) async throws -> ListTasksResponse
}

enum TaskStoreError: Error {
    case concurrentModification
    case taskAlreadyExists
    case taskNotFound
    case invalidRequest(String)
}
```

### OCC Conflict Resolution Strategy
When `update()` returns `.concurrentModification`:
1. Fetch latest task from store using `get()`
2. Retry up to 10 times (for cancellation requests)
3. If task is in terminal state, accept and return success
4. If still in non-terminal state, retry update

---

## 4. TaskUpdateManager

### Go Definition (internal/taskupdate/manager.go)
```go
type Manager struct {
    taskInfo   a2a.TaskInfo
    lastStored *taskstore.StoredTask
    store      taskstore.Store
}

func (mgr *Manager) Process(ctx context.Context, event a2a.Event) (*taskstore.StoredTask, error) {
    // Validates event, applies state transitions, stores result
}

func (mgr *Manager) SetTaskFailed(ctx context.Context, event a2a.Event, cause error) 
    (*taskstore.StoredTask, error) {
    // Moves task to failed state
}
```

### Swift Equivalent
```swift
// Sources/A2A/Server/TaskUpdateManager.swift

class TaskUpdateManager {
    let taskInfo: TaskInfo
    private var lastStored: StoredTask?
    let store: TaskStore
    
    init(taskInfo: TaskInfo, store: TaskStore, task: StoredTask? = nil) {
        self.taskInfo = taskInfo
        self.lastStored = task
        self.store = store
    }
    
    /// Process a new event from the agent, update task state and store.
    /// Returns updated StoredTask.
    func process(_ event: Event) async throws -> StoredTask {
        // Step 1: Validate event type
        if let message = event as? Message {
            if lastStored != nil {
                throw TaskUpdateError.messageNotAllowedAfterTaskStored
            }
            return lastStored!  // Already created
        }
        
        // Step 2: Check if task is in terminal state
        if lastStored != nil && lastStored!.task.status.state.isTerminal {
            if lastStored!.task == event {
                return lastStored!  // Idempotency
            }
            throw TaskUpdateError.invalidStateUpdate
        }
        
        // Step 3: Process Task event
        if let task = event as? Task {
            try validate(task)
            return try await saveTask(task)
        }
        
        // Step 4: Process subsequent events
        guard lastStored != nil else {
            throw TaskUpdateError.firstEventMustBeTaskOrMessage
        }
        
        switch event {
        case let artifactEvent as TaskArtifactUpdateEvent:
            try validate(artifactEvent)
            return try await updateArtifact(artifactEvent)
            
        case let statusEvent as TaskStatusUpdateEvent:
            try validate(statusEvent)
            return try await updateStatus(statusEvent)
            
        default:
            throw TaskUpdateError.unexpectedEventType
        }
    }
    
    /// Mark task as failed (error recovery).
    func setTaskFailed(_ cause: Error) async throws -> StoredTask {
        guard let lastStored = lastStored else {
            throw TaskUpdateError.executionFailedBeforeTaskCreated(cause)
        }
        
        var task = lastStored.task
        task.status = TaskStatus(state: .failed)
        return try await saveTask(task)
    }
    
    // MARK: - Private Methods
    
    private func updateArtifact(_ event: TaskArtifactUpdateEvent) async throws -> StoredTask {
        var task = try deepCopy(lastStored!.task)
        let artifact = try deepCopy(event.artifact)
        
        // Find existing artifact by ID
        if let index = task.artifacts.firstIndex(where: { $0.id == artifact.id }) {
            if !event.append {
                // Replace
                task.artifacts[index] = artifact
            } else {
                // Append parts and metadata
                task.artifacts[index].parts.append(contentsOf: artifact.parts)
                if task.artifacts[index].metadata == nil {
                    task.artifacts[index].metadata = artifact.metadata ?? [:]
                } else {
                    task.artifacts[index].metadata?.merge(artifact.metadata ?? [:]) { _, new in new }
                }
            }
        } else if event.append {
            // New artifact
            task.artifacts.append(artifact)
        } else {
            throw TaskUpdateError.artifactNotFound
        }
        
        return try await saveTask(task)
    }
    
    private func updateStatus(_ event: TaskStatusUpdateEvent) async throws -> StoredTask {
        var lastStored = try deepCopy(self.lastStored!)
        
        // Retry up to 10 times for cancellation requests
        for attempt in 0..<maxCancellationAttempts {
            let task = lastStored.task
            
            if let message = task.status.message {
                task.history.append(message)
            }
            
            if let metadata = event.metadata {
                if task.metadata == nil {
                    task.metadata = [:]
                }
                task.metadata?.merge(metadata) { _, new in new }
            }
            
            task.status = event.status
            
            do {
                let result = try await saveVersionedTask(task, version: lastStored.version)
                self.lastStored = result
                return result
            } catch TaskStoreError.concurrentModification {
                if event.status.state != .canceled {
                    throw TaskStoreError.concurrentModification
                }
                
                // Retry: fetch latest state
                let updated = try await store.get(taskID: event.taskID)
                
                if updated.task.status.state == .canceled {
                    self.lastStored = updated
                    return updated
                }
                
                if updated.task.status.state.isTerminal {
                    throw TaskStoreError.concurrentModification
                }
                
                lastStored = updated
            }
        }
        
        throw TaskUpdateError.maxCancellationAttemptsReached
    }
    
    private func saveTask(_ task: Task) async throws -> StoredTask {
        let version = lastStored?.version ?? taskVersionMissing
        return try await saveVersionedTask(task, version: version)
    }
    
    private func saveVersionedTask(_ task: Task, version: TaskVersion) async throws -> StoredTask {
        let newVersion: TaskVersion
        
        if lastStored == nil {
            newVersion = try await store.create(task: task)
        } else {
            let request = UpdateRequest(task: task, event: nil, prevVersion: version)
            newVersion = try await store.update(request: request)
        }
        
        let result = StoredTask(task: task, version: newVersion)
        self.lastStored = result
        return result
    }
    
    private func validate(_ event: TaskInfoProvider) throws {
        let info = event.taskInfo()
        if taskInfo.taskID != info.taskID {
            throw TaskUpdateError.taskIDMismatch
        }
        if taskInfo.contextID != info.contextID {
            throw TaskUpdateError.contextIDMismatch
        }
    }
}

enum TaskUpdateError: Error {
    case messageNotAllowedAfterTaskStored
    case invalidStateUpdate
    case firstEventMustBeTaskOrMessage
    case unexpectedEventType
    case executionFailedBeforeTaskCreated(Error)
    case artifactNotFound
    case maxCancellationAttemptsReached
    case taskIDMismatch
    case contextIDMismatch
}

private let maxCancellationAttempts = 10
```

---

## 5. Push Notification System

### Go Definition (a2asrv/push/api.go, sender.go)
```go
type Sender interface {
    SendPush(ctx context.Context, config *a2a.PushConfig, event a2a.Event) error
}

type ConfigStore interface {
    Save(ctx context.Context, taskID a2a.TaskID, config *a2a.PushConfig) (*a2a.PushConfig, error)
    Get(ctx context.Context, taskID a2a.TaskID, configID string) (*a2a.PushConfig, error)
    List(ctx context.Context, taskID a2a.TaskID) ([]*a2a.PushConfig, error)
    Delete(ctx context.Context, taskID a2a.TaskID, configID string) error
    DeleteAll(ctx context.Context, taskID a2a.TaskID) error
}

// HTTP implementation
type HTTPPushSender struct {
    client        *http.Client
    failOnError   bool
}

func (s *HTTPPushSender) SendPush(ctx context.Context, config *a2a.PushConfig, event a2a.Event) error {
    body := marshallEventAsStreamResponse(event)
    
    req, _ := http.NewRequestWithContext(ctx, "POST", config.URL, body)
    req.Header.Set("Content-Type", "application/json")
    req.Header.Set("A2A-Notification-Token", config.Token)
    
    if config.Authorization != nil {
        // Add Bearer or Basic auth
    }
    
    resp, _ := s.client.Do(req)
    if resp.StatusCode < 200 || resp.StatusCode >= 300 {
        return fmt.Errorf("push failed: %d", resp.StatusCode)
    }
}
```

### Swift Equivalent
```swift
// Sources/A2A/Server/PushNotifications.swift

protocol PushSender: AnyObject {
    /// Send push notification to endpoint.
    func sendPush(config: PushConfig, event: Event) async throws
}

protocol PushConfigStore: AnyObject {
    /// Save or update a push config. Returns config with ID assigned by store.
    func save(taskID: TaskID, config: PushConfig) async throws -> PushConfig
    
    /// Get config by ID.
    func get(taskID: TaskID, configID: String) async throws -> PushConfig
    
    /// List all configs for a task.
    func list(taskID: TaskID) async throws -> [PushConfig]
    
    /// Delete config by ID.
    func delete(taskID: TaskID, configID: String) async throws
    
    /// Delete all configs for a task.
    func deleteAll(taskID: TaskID) async throws
}

// Sources/A2A/Server/HTTPPushSender.swift

class HTTPPushSender: PushSender {
    let session: URLSession
    let failOnError: Bool
    
    init(session: URLSession = .shared, failOnError: Bool = true) {
        self.session = session
        self.failOnError = failOnError
    }
    
    func sendPush(config: PushConfig, event: Event) async throws {
        let body = try encodeEventAsStreamResponse(event)
        
        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.token, forHTTPHeaderField: "A2A-Notification-Token")
        
        // Add auth header if provided
        if let auth = config.authorization {
            switch auth {
            case .bearer(let token):
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            case .basic(let username, let password):
                let credentials = "\(username):\(password)".data(using: .utf8)!.base64EncodedString()
                request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            }
        }
        
        request.httpBody = body
        
        let (_, response) = try await session.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        
        if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
            let error = PushError.failedWithStatus(httpResponse.statusCode)
            if failOnError {
                throw error
            }
        }
    }
}

// In-memory implementation
class InMemoryPushConfigStore: PushConfigStore {
    private var configs: [String: [String: PushConfig]] = [:]  // [taskID: [configID: config]]
    private let lock = NSLock()
    private var idCounter: Int = 0
    
    func save(taskID: TaskID, config: PushConfig) async throws -> PushConfig {
        lock.lock()
        defer { lock.unlock() }
        
        var config = config
        if config.id.isEmpty {
            idCounter += 1
            config.id = "config-\(idCounter)"
        }
        
        if configs[taskID] == nil {
            configs[taskID] = [:]
        }
        configs[taskID]![config.id] = config
        
        return config
    }
    
    func get(taskID: TaskID, configID: String) async throws -> PushConfig {
        lock.lock()
        defer { lock.unlock() }
        
        guard let config = configs[taskID]?[configID] else {
            throw PushError.configNotFound
        }
        return config
    }
    
    func list(taskID: TaskID) async throws -> [PushConfig] {
        lock.lock()
        defer { lock.unlock() }
        
        return Array(configs[taskID]?.values ?? [:].values)
    }
    
    func delete(taskID: TaskID, configID: String) async throws {
        lock.lock()
        defer { lock.unlock() }
        
        configs[taskID]?.removeValue(forKey: configID)
    }
    
    func deleteAll(taskID: TaskID) async throws {
        lock.lock()
        defer { lock.unlock() }
        
        configs.removeValue(forKey: taskID)
    }
}

enum PushError: Error {
    case failedWithStatus(Int)
    case configNotFound
}
```

---

## 6. Event Finalization

### Go Definition (internal/taskupdate/final.go)
```go
func IsFinal(event a2a.Event) bool {
    if _, ok := event.(*a2a.Message); ok {
        return true
    }
    
    var state a2a.TaskState
    switch v := event.(type) {
    case *a2a.TaskStatusUpdateEvent:
        state = v.Status.State
    case *a2a.Task:
        state = v.Status.State
    default:
        return false
    }
    
    return state.Terminal() || state == a2a.TaskStateInputRequired
}
```

### Swift Equivalent
```swift
// Sources/A2A/Server/ExecutionTermination.swift

/// Determine if an event terminates execution.
func isFinal(_ event: Event) -> Bool {
    if event is Message {
        return true
    }
    
    let state: TaskState?
    
    if let statusEvent = event as? TaskStatusUpdateEvent {
        state = statusEvent.status.state
    } else if let task = event as? Task {
        state = task.status.state
    } else {
        return false
    }
    
    return state?.isTerminal ?? false || state == .inputRequired
}
```

---

## 7. HTTP Routing & RequestHandler

### Go Definition (a2asrv/handler.go, rest.go)
```go
type RequestHandler interface {
    SendMessage(ctx context.Context, req *a2a.SendMessageRequest) (*a2a.SendMessageResult, error)
    StreamMessage(ctx context.Context, req *a2a.SendMessageRequest) (a2a.StreamResponse, error)
    GetTask(ctx context.Context, req *a2a.GetTaskRequest) (*a2a.GetTaskResponse, error)
    CancelTask(ctx context.Context, req *a2a.CancelTaskRequest) (*a2a.Task, error)
    SavePushConfig(ctx context.Context, req *a2a.SavePushConfigRequest) (*a2a.SavePushConfigResponse, error)
    GetPushConfig(ctx context.Context, req *a2a.GetPushConfigRequest) (*a2a.PushConfig, error)
    DeletePushConfig(ctx context.Context, req *a2a.DeletePushConfigRequest) (*a2a.DeletePushConfigResponse, error)
    GetExtendedAgentCard(ctx context.Context, req *a2a.GetExtendedAgentCardRequest) (*a2a.AgentCard, error)
}

// REST routes
// POST /tasks - sendMessage/streamMessage
// GET /tasks/{id} - getTask
// POST /tasks/{id}:cancel - cancelTask
// GET /.well-known/a2a/card - getCard
// POST /push-configs - savePushConfig
// GET /push-configs/{id} - getPushConfig
// DELETE /push-configs/{id} - deletePushConfig
```

### Swift Equivalent
```swift
// Sources/A2A/Server/RequestHandler.swift

protocol RequestHandler: AnyObject {
    func sendMessage(request: SendMessageRequest) async throws -> SendMessageResult
    func streamMessage(request: SendMessageRequest) async throws -> AsyncStream<StreamResponse>
    func getTask(request: GetTaskRequest) async throws -> GetTaskResponse
    func cancelTask(request: CancelTaskRequest) async throws -> Task
    func savePushConfig(request: SavePushConfigRequest) async throws -> SavePushConfigResponse
    func getPushConfig(request: GetPushConfigRequest) async throws -> PushConfig
    func deletePushConfig(request: DeletePushConfigRequest) async throws -> DeletePushConfigResponse
    func getExtendedAgentCard(request: GetExtendedAgentCardRequest) async throws -> AgentCard
}

// Sources/A2A/Server/A2AServer.swift

class A2AServer {
    let handler: RequestHandler
    let agentCard: AgentCard
    
    // REST routes:
    // POST /tasks - sendMessage + streamMessage
    // GET /tasks/{id} - getTask
    // POST /tasks/{id}:cancel - cancelTask
    // GET /.well-known/a2a/card - getCard
    // POST /push-configs - savePushConfig
    // GET /push-configs/{id} - getPushConfig
    // DELETE /push-configs/{id} - deletePushConfig
    
    func setupRoutes(_ app: some HTTPApplication) {
        // Use your web framework (Vapor, Hummingbird, etc.)
    }
}
```

---

## 8. Execution Manager (Local Mode)

### Go Definition (internal/taskexec/api.go)
```go
type Manager interface {
    Resubscribe(ctx context.Context, taskID a2a.TaskID) (Subscription, error)
    Execute(ctx context.Context, req *a2a.SendMessageRequest) (Subscription, error)
    Cancel(ctx context.Context, req *a2a.CancelTaskRequest) (*a2a.Task, error)
}

type Subscription interface {
    TaskID() a2a.TaskID
    Events(ctx context.Context) iter.Seq2[a2a.Event, error]
}

type Processor interface {
    Process(context.Context, a2a.Event) (*ProcessorResult, error)
    ProcessError(context.Context, error) (a2a.SendMessageResult, error)
}

type ProcessorResult struct {
    ExecutionResult        a2a.SendMessageResult
    ExecutionFailureCause  error
    TaskVersion            taskstore.TaskVersion
    EventOverride          a2a.Event
}
```

### Swift Equivalent
```swift
// Sources/A2A/Server/ExecutionManager.swift

protocol ExecutionManager: AnyObject {
    func resubscribe(taskID: TaskID) async throws -> ExecutionSubscription
    func execute(request: SendMessageRequest) async throws -> ExecutionSubscription
    func cancel(request: CancelTaskRequest) async throws -> Task
}

protocol ExecutionSubscription {
    func taskID() -> TaskID
    func events() -> AsyncThrowingSequence<Event, Error>
}

protocol EventProcessor {
    func process(_ event: Event) async throws -> ProcessorResult
    func processError(_ error: Error) async throws -> SendMessageResult
}

struct ProcessorResult {
    let executionResult: SendMessageResult?
    let executionFailureCause: Error?
    let taskVersion: TaskVersion
    let eventOverride: Event?
}

// Implementation for local execution
class LocalExecutionManager: ExecutionManager {
    let factory: ExecutionFactory
    let taskStore: TaskStore
    let eventBus: EventBus  // For broadcasting to multiple subscribers
    
    func execute(request: SendMessageRequest) async throws -> ExecutionSubscription {
        let (executor, processor, cleaner) = try await factory.createExecutor(request.taskID, request)
        
        // Start execution in background task
        Task {
            do {
                let events = executor.execute(context: await loadContext(request.taskID, request))
                for try await event in events {
                    let result = try await processor.process(event)
                    await eventBus.broadcast(event)
                    
                    if result.executionResult != nil {
                        await cleaner.cleanup(result: result.executionResult!, error: nil)
                        return
                    }
                }
            } catch {
                let result = try await processor.processError(error)
                await cleaner.cleanup(result: result, error: error)
            }
        }
        
        return LocalExecutionSubscription(taskID: request.taskID, eventBus: eventBus)
    }
}

class LocalExecutionSubscription: ExecutionSubscription {
    let taskID: TaskID
    let eventBus: EventBus
    
    func taskID() -> TaskID {
        self.taskID
    }
    
    func events() -> AsyncThrowingSequence<Event, Error> {
        eventBus.subscribe(taskID: taskID)
    }
}
```

---

## 9. Key Design Patterns

### Pattern 1: Event-Driven Streaming
```swift
// Instead of returning Array<Event>, return AsyncSequence<Event>
// Uses AsyncStream internally in Go (iter.Seq2), AsyncThrowingSequence in Swift

func execute(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error> {
    AsyncThrowingStream { continuation in
        do {
            let response1 = try await model.call(context.message)
            continuation.yield(try Task.create(...))
            
            for try await chunk in response1.stream {
                continuation.yield(try TaskArtifactUpdateEvent.create(...))
            }
            
            continuation.yield(try TaskStatusUpdateEvent.create(state: .completed))
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
```

### Pattern 2: Optimistic Concurrency Control Retry
```swift
// Retry up to 10 times on concurrent modification
for attempt in 0..<10 {
    do {
        return try await taskStore.update(...)
    } catch TaskStoreError.concurrentModification {
        if statusEvent.state != .canceled {
            throw error
        }
        let latest = try await taskStore.get(taskID: taskID)
        if latest.task.status.state == .canceled {
            return latest  // Success!
        }
        if latest.task.status.state.isTerminal {
            throw error  // Can't retry
        }
        // Continue loop to retry
    }
}
```

### Pattern 3: Task-Local Context
```swift
// Store context in task local for access in nested calls
@TaskLocal static var executorContext: ExecutorContext?

// In Execute:
try await Task {
    self.$executorContext.withValue(context) {
        // Now accessible via ExecutorContext.current
    }
}.value
```

---

## 10. Integration Checklist for Phase 8

- [ ] **TaskStore** - Implement in-memory version first, then persistent backend
- [ ] **AgentExecutor** - Create test implementation returning simple events
- [ ] **ExecutorContext** - Build with minimal fields, expand as needed
- [ ] **TaskUpdateManager** - Implement state machine validation
- [ ] **PushNotifications** - Stub with no-op Sender initially
- [ ] **HTTPPushSender** - Full implementation with error handling
- [ ] **InMemoryPushConfigStore** - Thread-safe in-memory store
- [ ] **A2AServer** - Route handlers using preferred web framework
- [ ] **ExecutionManager** - Local mode with event broadcasting
- [ ] **Tests** - Full coverage with Go SDK alignment

---

## Next Steps

1. **Create foundational types** (A, B, C in parallel)
2. **Implement TaskUpdateManager** (core state machine)
3. **Add push notification system**
4. **Build A2AServer HTTP routing**
5. **Create ExecutionManager for streaming**
6. **Comprehensive testing suite**

