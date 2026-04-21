# Phase 8: Swift Server SDK — Implementation Patterns & Code Examples

## Quick Start: Complete Working Example

```swift
// Step 1: Define a custom AgentExecutor

class SimpleEchoAgent: AgentExecutor, AgentExecutionCleaner {
    func execute(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error> {
        AsyncThrowingStream { continuation in
            do {
                // Step 1: Create task if first time
                if context.storedTask == nil {
                    let task = Task(
                        id: context.taskID,
                        status: TaskStatus(state: .submitted),
                        artifacts: [],
                        history: [],
                        metadata: context.metadata
                    )
                    continuation.yield(task)
                }
                
                // Step 2: Send working status
                let working = TaskStatusUpdateEvent(
                    taskID: context.taskID,
                    status: TaskStatus(state: .working)
                )
                continuation.yield(working)
                
                // Step 3: Create artifact and stream parts
                let artifact = TaskArtifactUpdateEvent(
                    taskID: context.taskID,
                    artifactID: "output-1",
                    parts: [ArtifactPart(data: "Echo: \(context.message?.payload ?? "")")],
                    append: false
                )
                continuation.yield(artifact)
                
                // Step 4: Mark as completed
                let completed = TaskStatusUpdateEvent(
                    taskID: context.taskID,
                    status: TaskStatus(state: .completed)
                )
                continuation.yield(completed)
                
                continuation.finish()
            } catch {
                let failed = TaskStatusUpdateEvent(
                    taskID: context.taskID,
                    status: TaskStatus(state: .failed)
                )
                try? continuation.yield(failed)
                continuation.finish(throwing: error)
            }
        }
    }
    
    func cancel(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error> {
        AsyncThrowingStream { continuation in
            let canceled = TaskStatusUpdateEvent(
                taskID: context.taskID,
                status: TaskStatus(state: .canceled)
            )
            continuation.yield(canceled)
            continuation.finish()
        }
    }
    
    func cleanup(context: ExecutorContext, result: SendMessageResult, error: Error?) async {
        if let error = error {
            print("Execution failed: \(error)")
        } else {
            print("Execution completed successfully")
        }
    }
}

// Step 2: Setup TaskStore

class InMemoryTaskStore: TaskStore {
    private var tasks: [String: StoredTask] = [:]
    private var versions: [String: TaskVersion] = [:]
    private let lock = NSLock()
    
    func create(task: Task) async throws -> TaskVersion {
        lock.lock()
        defer { lock.unlock() }
        
        if tasks[task.id.value] != nil {
            throw TaskStoreError.taskAlreadyExists
        }
        
        let version: TaskVersion = 1
        tasks[task.id.value] = StoredTask(task: task, version: version)
        return version
    }
    
    func update(request: UpdateRequest) async throws -> TaskVersion {
        lock.lock()
        defer { lock.unlock() }
        
        guard let stored = tasks[request.task.id.value] else {
            throw TaskStoreError.taskNotFound
        }
        
        // Check OCC
        if !request.prevVersion.after(stored.version) {
            throw TaskStoreError.concurrentModification
        }
        
        let newVersion = stored.version + 1
        tasks[request.task.id.value] = StoredTask(task: request.task, version: newVersion)
        return newVersion
    }
    
    func get(taskID: TaskID) async throws -> StoredTask {
        lock.lock()
        defer { lock.unlock() }
        
        guard let stored = tasks[taskID.value] else {
            throw TaskStoreError.taskNotFound
        }
        return stored
    }
    
    func list(request: ListTasksRequest) async throws -> ListTasksResponse {
        lock.lock()
        defer { lock.unlock() }
        
        let allTasks = Array(tasks.values.map { $0.task })
        return ListTasksResponse(tasks: allTasks)
    }
}

// Step 3: Setup and run server

let agent = SimpleEchoAgent()
let taskStore = InMemoryTaskStore()
let handler = DefaultRequestHandler(agent: agent, taskStore: taskStore)
let server = A2AServer(handler: handler, agentCard: /* your card */)

// Register routes (pseudo-code for your web framework)
// app.post("/tasks", handler: server.handleSendMessage)
// app.post("/tasks/:id:cancel", handler: server.handleCancelTask)
// etc.
```

---

## AsyncThrowingSequence Patterns

### Pattern 1: Simple Emission
```swift
func execute(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(event1)
        continuation.yield(event2)
        continuation.finish()
    }
}
```

### Pattern 2: Error Handling
```swift
func execute(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error> {
    AsyncThrowingStream { continuation in
        do {
            let result = try await processMessage(context.message)
            continuation.yield(result)
            continuation.finish()
        } catch {
            // Emit failure event then throw
            let failed = TaskStatusUpdateEvent(
                taskID: context.taskID,
                status: TaskStatus(state: .failed)
            )
            continuation.yield(failed)
            continuation.finish(throwing: error)
        }
    }
}
```

### Pattern 3: Streaming from External Source
```swift
func execute(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                for try await output in model.stream(context.message) {
                    let event = TaskArtifactUpdateEvent(...)
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
```

### Pattern 4: Consuming AsyncSequence in Swift
```swift
let subscription = try await executionManager.execute(request)
let events = subscription.events()

do {
    for try await event in events {
        if let task = event as? Task {
            print("Task created: \(task.id)")
        } else if let statusEvent = event as? TaskStatusUpdateEvent {
            print("Status updated: \(statusEvent.status.state)")
        }
    }
} catch {
    print("Execution failed: \(error)")
}
```

---

## State Machine Implementation

### Pattern 1: Task State Validation

```swift
class TaskUpdateManager {
    /// Validates transition based on current state
    private func validateTransition(from: TaskState, to: TaskState) throws {
        // Terminal states cannot transition
        if from.isTerminal {
            throw TaskUpdateError.invalidStateTransition
        }
        
        // Only certain transitions are allowed
        let allowed: [TaskState: Set<TaskState>] = [
            .submitted: [.working, .canceled, .failed],
            .working: [.completed, .failed, .canceled, .inputRequired],
            .inputRequired: [.working, .canceled, .failed],
            .completed: [],  // Terminal
            .failed: [],     // Terminal
            .canceled: [],   // Terminal
            .rejected: [],   // Terminal
            .authRequired: [.working, .canceled, .failed]
        ]
        
        if allowed[from]?.contains(to) != true {
            throw TaskUpdateError.invalidTransition(from: from, to: to)
        }
    }
}
```

### Pattern 2: Event Type Dispatch

```swift
func process(_ event: Event) async throws -> StoredTask {
    if let message = event as? Message {
        // Message type handling
        if lastStored != nil {
            throw TaskUpdateError.messageNotAllowedAfterTaskStored
        }
        return lastStored!
    }
    
    if let task = event as? Task {
        // Task type handling
        try validate(task)
        return try await saveTask(task)
    }
    
    if let statusEvent = event as? TaskStatusUpdateEvent {
        try validate(statusEvent)
        return try await updateStatus(statusEvent)
    }
    
    if let artifactEvent = event as? TaskArtifactUpdateEvent {
        try validate(artifactEvent)
        return try await updateArtifact(artifactEvent)
    }
    
    throw TaskUpdateError.unexpectedEventType
}
```

---

## Concurrency Patterns

### Pattern 1: OCC Retry Loop

```swift
private func updateStatus(_ event: TaskStatusUpdateEvent) async throws -> StoredTask {
    var lastStored = try deepCopy(self.lastStored!)
    
    for attempt in 0..<10 {
        let task = lastStored.task
        
        // Prepare update
        task.status = event.status
        if let metadata = event.metadata {
            task.metadata?.merge(metadata) { _, new in new }
        }
        
        // Try to save with OCC
        do {
            let result = try await saveVersionedTask(task, version: lastStored.version)
            self.lastStored = result
            return result
        } catch TaskStoreError.concurrentModification {
            // Only retry for cancellation
            if event.status.state != .canceled {
                throw TaskStoreError.concurrentModification
            }
            
            // Fetch latest state
            let updated = try await store.get(taskID: task.id)
            
            // Check if already canceled
            if updated.task.status.state == .canceled {
                self.lastStored = updated
                return updated
            }
            
            // Terminal states can't retry
            if updated.task.status.state.isTerminal {
                throw TaskStoreError.concurrentModification
            }
            
            // Update state and retry
            lastStored = updated
        }
    }
    
    throw TaskUpdateError.maxCancellationAttemptsReached
}
```

### Pattern 2: Task-Local Context

```swift
// Define task-local key
private enum ExecutorContextKey: TaskLocalKey {
    typealias Value = ExecutorContext
}

extension ExecutorContext {
    @TaskLocal static var current: ExecutorContext?
    
    // Usage:
    // ExecutorContext.$current.withValue(context) { ... }
}

// Access in nested function
func processMessage() -> String {
    guard let context = ExecutorContext.current else {
        fatalError("No executor context")
    }
    return context.message?.payload ?? "No message"
}
```

---

## Push Notification Implementation

### Pattern 1: HTTPPushSender with Retries

```swift
class HTTPPushSender: PushSender {
    let session: URLSession
    let maxRetries: Int = 3
    
    func sendPush(config: PushConfig, event: Event) async throws {
        let body = try encodeEventAsJSON(event)
        
        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.token, forHTTPHeaderField: "A2A-Notification-Token")
        
        addAuthHeader(to: &request, config: config)
        request.httpBody = body
        
        // Retry with exponential backoff
        for attempt in 0..<maxRetries {
            do {
                let (_, response) = try await session.data(for: request)
                let httpResponse = response as! HTTPURLResponse
                
                if (200..<300).contains(httpResponse.statusCode) {
                    return  // Success
                }
                
                throw PushError.httpError(statusCode: httpResponse.statusCode)
            } catch {
                if attempt == maxRetries - 1 {
                    throw error  // Final attempt failed
                }
                
                // Exponential backoff: 100ms, 200ms, 400ms
                let backoff = UInt64(100 * (1 << attempt)) * 1_000_000  // nanoseconds
                try await Task.sleep(nanoseconds: backoff)
            }
        }
    }
    
    private func addAuthHeader(to request: inout URLRequest, config: PushConfig) {
        guard let auth = config.authorization else { return }
        
        switch auth {
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .basic(let username, let password):
            if let data = "\(username):\(password)".data(using: .utf8) {
                let encoded = data.base64EncodedString()
                request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
            }
        }
    }
}
```

---

## Artifact Handling Patterns

### Pattern 1: Append vs Replace

```swift
private func updateArtifact(_ event: TaskArtifactUpdateEvent) async throws -> StoredTask {
    var task = try deepCopy(lastStored!.task)
    let artifact = try deepCopy(event.artifact)
    
    if let index = task.artifacts.firstIndex(where: { $0.id == artifact.id }) {
        if event.append {
            // Append parts and metadata
            task.artifacts[index].parts.append(contentsOf: artifact.parts)
            
            if task.artifacts[index].metadata != nil && artifact.metadata != nil {
                task.artifacts[index].metadata?.merge(artifact.metadata!) { _, new in new }
            } else if artifact.metadata != nil {
                task.artifacts[index].metadata = artifact.metadata
            }
        } else {
            // Replace entire artifact
            task.artifacts[index] = artifact
        }
    } else if !event.append {
        // New artifact with replace flag = error
        throw TaskUpdateError.artifactNotFound
    } else {
        // New artifact
        task.artifacts.append(artifact)
    }
    
    return try await saveTask(task)
}
```

### Pattern 2: Streaming Large Artifacts

```swift
func execute(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error> {
    AsyncThrowingStream { continuation in
        do {
            // Create initial artifact
            var artifactID: String?
            let streamResponse = try await model.stream(context.message)
            
            for try await chunk in streamResponse {
                let part = ArtifactPart(data: chunk)
                
                if artifactID == nil {
                    // First chunk: create new artifact
                    let event = TaskArtifactUpdateEvent(
                        taskID: context.taskID,
                        artifactID: UUID().uuidString,
                        parts: [part],
                        append: false
                    )
                    artifactID = event.artifactID
                    continuation.yield(event)
                } else {
                    // Subsequent chunks: append
                    let event = TaskArtifactUpdateEvent(
                        taskID: context.taskID,
                        artifactID: artifactID!,
                        parts: [part],
                        append: true
                    )
                    continuation.yield(event)
                }
            }
            
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
```

---

## Deep Copy Helper

```swift
private func deepCopy<T: Codable>(_ value: T) throws -> T {
    let encoded = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: encoded)
}

// Alternative: Use Swift's struct value semantics directly
// For reference types, implement NSCopying or use alternative patterns
```

---

## Testing Patterns

### Pattern 1: Mock AgentExecutor

```swift
class MockAgentExecutor: AgentExecutor, AgentExecutionCleaner {
    var executeEvents: [Event] = []
    var cancelEvents: [Event] = []
    var shouldThrow: Error?
    
    func execute(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error> {
        AsyncThrowingStream { continuation in
            if let error = shouldThrow {
                continuation.finish(throwing: error)
            } else {
                for event in executeEvents {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
    
    func cancel(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error> {
        AsyncThrowingStream { continuation in
            for event in cancelEvents {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
    
    func cleanup(context: ExecutorContext, result: SendMessageResult, error: Error?) async {
        // Track cleanup calls
    }
}

// Usage in tests
func testExecutionFlow() async throws {
    let agent = MockAgentExecutor()
    agent.executeEvents = [
        Task(id: "task-1", status: TaskStatus(state: .submitted), ...),
        TaskStatusUpdateEvent(taskID: "task-1", status: TaskStatus(state: .working)),
        TaskStatusUpdateEvent(taskID: "task-1", status: TaskStatus(state: .completed))
    ]
    
    // Test execution
}
```

### Pattern 2: Mock TaskStore

```swift
class MockTaskStore: TaskStore {
    var createdTasks: [Task] = []
    var updatedTasks: [(UpdateRequest, TaskVersion)] = []
    
    func create(task: Task) async throws -> TaskVersion {
        createdTasks.append(task)
        return 1
    }
    
    func update(request: UpdateRequest) async throws -> TaskVersion {
        let version = TaskVersion(updatedTasks.count + 1)
        updatedTasks.append((request, version))
        return version
    }
    
    // ... other methods
}
```

---

## Error Handling Strategies

```swift
enum ExecutionError: Error {
    case agentFailed(String)
    case taskNotFound
    case invalidTransition(from: TaskState, to: TaskState)
    case concurrentModification
    case networkError(Error)
    case timeout
}

// In AgentExecutor implementation
func handleError(_ error: Error, context: ExecutorContext) -> Event {
    let statusEvent = TaskStatusUpdateEvent(
        taskID: context.taskID,
        status: TaskStatus(state: .failed, message: "Error: \(error)")
    )
    return statusEvent
}
```

---

## Integration with Web Framework (Vapor Example)

```swift
import Vapor

extension A2AServer {
    func setupRoutes(_ app: Application) throws {
        let api = app.grouped("api")
        
        // POST /api/tasks - send message
        api.post("tasks") { req -> EventStream in
            let request = try req.content.decode(SendMessageRequest.self)
            let subscription = try await handler.execute(request: request)
            return EventStream(subscription: subscription)
        }
        
        // GET /api/tasks/:id - get task
        api.get("tasks", ":id") { req -> Task in
            guard let taskID = req.parameters.get("id") else {
                throw Abort(.badRequest)
            }
            let request = GetTaskRequest(taskID: TaskID(value: taskID))
            let response = try await handler.getTask(request: request)
            return response.task
        }
        
        // POST /api/tasks/:id:cancel - cancel
        api.post("tasks", ":id", ":cancel") { req -> Task in
            guard let taskID = req.parameters.get("id") else {
                throw Abort(.badRequest)
            }
            let request = CancelTaskRequest(taskID: TaskID(value: taskID))
            return try await handler.cancelTask(request: request)
        }
    }
}

// EventStream helper for SSE
struct EventStream: AsyncResponseEncodable {
    let subscription: ExecutionSubscription
    
    func encodeResponse(for request: Request) async throws -> Response {
        let response = Response(status: .ok)
        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        
        var buffer = ""
        for try await event in subscription.events() {
            let json = try JSONEncoder().encode(event)
            let line = "data: \(String(data: json, encoding: .utf8)!)\n\n"
            buffer += line
        }
        response.body = .init(string: buffer)
        return response
    }
}
```

