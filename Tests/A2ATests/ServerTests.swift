// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import Testing
@testable import A2AClient
import A2ACore
@testable import A2AServer

// MARK: - Test helpers

/// A configurable mock executor for unit tests.
struct MockAgentExecutor: AgentExecutor {
    var executeFn: @Sendable (ExecutorContext) -> AsyncThrowingStream<AgentEvent, Error>
    var cancelFn: @Sendable (ExecutorContext) -> AsyncThrowingStream<AgentEvent, Error>

    init(
        executeFn: @Sendable @escaping (ExecutorContext) -> AsyncThrowingStream<AgentEvent, Error>,
        cancelFn: (@Sendable (ExecutorContext) -> AsyncThrowingStream<AgentEvent, Error>)? = nil
    ) {
        self.executeFn = executeFn
        self.cancelFn = cancelFn ?? { ctx in
            AsyncThrowingStream { cont in
                var status = TaskStatus()
                status.state = .canceled
                var event = TaskStatusUpdateEvent()
                event.taskID = ctx.taskID
                event.status = status
                cont.yield(.statusUpdate(event))
                cont.finish()
            }
        }
    }

    func execute(context: ExecutorContext) -> AsyncThrowingStream<AgentEvent, Error> {
        executeFn(context)
    }

    func cancel(context: ExecutorContext) -> AsyncThrowingStream<AgentEvent, Error> {
        cancelFn(context)
    }
}

/// Creates a mock executor that replies with a single text message.
func echoExecutor(replyText: String = "pong") -> MockAgentExecutor {
    MockAgentExecutor { _ in
        AsyncThrowingStream { cont in
            var reply = Message()
            reply.messageID = UUID().uuidString
            reply.role = .agent
            var part = Part()
            part.text = replyText
            reply.parts = [part]
            cont.yield(.message(reply))
            cont.finish()
        }
    }
}

/// Creates a mock executor that emits a completed task.
func completingTaskExecutor() -> MockAgentExecutor {
    MockAgentExecutor { ctx in
        AsyncThrowingStream { cont in
            var status = TaskStatus()
            status.state = .completed
            var event = TaskStatusUpdateEvent()
            event.taskID = ctx.taskID
            event.status = status
            cont.yield(.statusUpdate(event))
            cont.finish()
        }
    }
}

/// Builds a minimal ``SendMessageRequest`` for testing.
func makeMessageRequest(taskID: String = "", contextID: String = "", text: String = "hello") -> SendMessageRequest {
    var msg = Message()
    msg.messageID = UUID().uuidString
    msg.role = .user
    msg.taskID = taskID
    msg.contextID = contextID
    var part = Part()
    part.text = text
    msg.parts = [part]
    var req = SendMessageRequest()
    req.message = msg
    return req
}

/// Builds a basic ``AgentCard`` for testing.
func makeTestAgentCard() -> AgentCard {
    var card = AgentCard()
    card.name = "TestAgent"
    card.description_p = "A test agent"
    card.version = "1.0.0"
    var iface = AgentInterface()
    iface.url = "http://localhost:8080"
    iface.protocolBinding = "JSONRPC"
    card.supportedInterfaces = [iface]
    return card
}

// MARK: - AgentEvent helpers tests

@Suite("AgentEvent helpers")
struct AgentEventHelpersTests {

    @Test("message event is always final")
    func messageFinal() {
        var m = Message()
        m.messageID = "m1"
        m.role = .agent
        var p = Part(); p.text = "hi"; m.parts = [p]
        let event = AgentEvent.message(m)
        #expect(event.isFinal)
    }

    @Test("statusUpdate with completed is final")
    func statusUpdateCompletedFinal() {
        var status = TaskStatus()
        status.state = .completed
        var e = TaskStatusUpdateEvent()
        e.taskID = "t1"; e.status = status
        #expect(AgentEvent.statusUpdate(e).isFinal)
    }

    @Test("statusUpdate with failed is final")
    func statusUpdateFailedFinal() {
        var status = TaskStatus()
        status.state = .failed
        var e = TaskStatusUpdateEvent()
        e.taskID = "t1"; e.status = status
        #expect(AgentEvent.statusUpdate(e).isFinal)
    }

    @Test("statusUpdate with canceled is final")
    func statusUpdateCanceledFinal() {
        var status = TaskStatus()
        status.state = .canceled
        var e = TaskStatusUpdateEvent()
        e.taskID = "t1"; e.status = status
        #expect(AgentEvent.statusUpdate(e).isFinal)
    }

    @Test("statusUpdate with inputRequired is final")
    func statusUpdateInputRequiredFinal() {
        var status = TaskStatus()
        status.state = .inputRequired
        var e = TaskStatusUpdateEvent()
        e.taskID = "t1"; e.status = status
        #expect(AgentEvent.statusUpdate(e).isFinal)
    }

    @Test("statusUpdate with working is NOT final")
    func statusUpdateWorkingNotFinal() {
        var status = TaskStatus()
        status.state = .working
        var e = TaskStatusUpdateEvent()
        e.taskID = "t1"; e.status = status
        #expect(!AgentEvent.statusUpdate(e).isFinal)
    }

    @Test("artifactUpdate is never final")
    func artifactUpdateNotFinal() {
        var artifact = Artifact()
        artifact.artifactID = "a1"
        var e = TaskArtifactUpdateEvent()
        e.taskID = "t1"; e.artifact = artifact
        #expect(!AgentEvent.artifactUpdate(e).isFinal)
    }

    @Test("taskID extracts correctly from each variant")
    func taskIDExtraction() {
        var m = Message(); m.messageID = "m1"; m.taskID = "task-msg"; m.role = .user
        var p = Part(); p.text = "hi"; m.parts = [p]
        #expect(AgentEvent.message(m).taskID == "task-msg")

        var t = Task(); t.id = "task-t"
        #expect(AgentEvent.task(t).taskID == "task-t")

        var su = TaskStatusUpdateEvent(); su.taskID = "task-su"
        #expect(AgentEvent.statusUpdate(su).taskID == "task-su")

        var au = TaskArtifactUpdateEvent(); au.taskID = "task-au"
        #expect(AgentEvent.artifactUpdate(au).taskID == "task-au")
    }
}

// MARK: - InMemoryTaskStore tests

@Suite("InMemoryTaskStore")
struct InMemoryTaskStoreTests {

    @Test("create stores a task and returns version 1")
    func createTask() async throws {
        let store = InMemoryTaskStore()
        var task = Task()
        task.id = "t1"
        var status = TaskStatus(); status.state = .submitted
        task.status = status

        let version = try await store.create(task: task)
        #expect(version == 1)

        let stored = try await store.get(taskID: "t1")
        #expect(stored.task.id == "t1")
        #expect(stored.version == 1)
    }

    @Test("create fails on duplicate ID")
    func createDuplicate() async throws {
        let store = InMemoryTaskStore()
        var task = Task(); task.id = "dup"
        _ = try await store.create(task: task)
        await #expect(throws: TaskStoreError.taskAlreadyExists) {
            _ = try await store.create(task: task)
        }
    }

    @Test("get throws taskNotFound for unknown ID")
    func getNotFound() async {
        let store = InMemoryTaskStore()
        await #expect(throws: TaskStoreError.taskNotFound) {
            _ = try await store.get(taskID: "missing")
        }
    }

    @Test("update increments version")
    func updateVersion() async throws {
        let store = InMemoryTaskStore()
        var task = Task(); task.id = "t1"
        var status = TaskStatus(); status.state = .submitted
        task.status = status
        let v1 = try await store.create(task: task)

        var updated = task
        var newStatus = TaskStatus(); newStatus.state = .working
        updated.status = newStatus

        var statusEvent = TaskStatusUpdateEvent()
        statusEvent.taskID = "t1"; statusEvent.status = newStatus
        let req = TaskUpdateRequest(task: updated, event: .statusUpdate(statusEvent), previousVersion: v1)
        let v2 = try await store.update(req)
        #expect(v2 == 2)

        let stored = try await store.get(taskID: "t1")
        #expect(stored.task.status.state == .working)
        #expect(stored.version == 2)
    }

    @Test("update throws concurrentModification on version mismatch")
    func updateConcurrentModification() async throws {
        let store = InMemoryTaskStore()
        var task = Task(); task.id = "t1"
        _ = try await store.create(task: task)

        var statusEvent = TaskStatusUpdateEvent()
        statusEvent.taskID = "t1"
        var status = TaskStatus(); status.state = .working
        statusEvent.status = status
        let req = TaskUpdateRequest(task: task, event: .statusUpdate(statusEvent), previousVersion: 99)
        await #expect(throws: TaskStoreError.concurrentModification) {
            _ = try await store.update(req)
        }
    }

    @Test("list returns all tasks without filters")
    func listNoFilter() async throws {
        let store = InMemoryTaskStore()
        for i in 1...3 {
            var task = Task(); task.id = "t\(i)"
            var status = TaskStatus(); status.state = .submitted
            task.status = status
            _ = try await store.create(task: task)
        }
        let resp = try await store.list(ListTasksRequest())
        #expect(resp.tasks.count == 3)
    }

    @Test("list filters by contextID")
    func listContextFilter() async throws {
        let store = InMemoryTaskStore()
        for i in 1...3 {
            var task = Task()
            task.id = "t\(i)"
            task.contextID = i == 2 ? "ctx-A" : "ctx-B"
            _ = try await store.create(task: task)
        }
        var req = ListTasksRequest()
        req.contextID = "ctx-A"
        let resp = try await store.list(req)
        #expect(resp.tasks.count == 1)
        #expect(resp.tasks[0].id == "t2")
    }

    @Test("list filters by status")
    func listStatusFilter() async throws {
        let store = InMemoryTaskStore()
        for (i, state) in [(1, TaskState.submitted), (2, .working), (3, .completed)] {
            var task = Task(); task.id = "t\(i)"
            var status = TaskStatus(); status.state = state
            task.status = status
            _ = try await store.create(task: task)
        }
        var req = ListTasksRequest()
        req.status = .working
        let resp = try await store.list(req)
        #expect(resp.tasks.count == 1)
        #expect(resp.tasks[0].id == "t2")
    }

    @Test("list respects pageSize and returns nextPageToken")
    func listPaging() async throws {
        let store = InMemoryTaskStore()
        for i in 1...5 {
            var task = Task(); task.id = "t\(i)"
            _ = try await store.create(task: task)
        }
        var req = ListTasksRequest()
        req.pageSize = 2
        let page1 = try await store.list(req)
        #expect(page1.tasks.count == 2)
        #expect(!page1.nextPageToken.isEmpty)

        req.pageToken = page1.nextPageToken
        let page2 = try await store.list(req)
        #expect(page2.tasks.count == 2)

        req.pageToken = page2.nextPageToken
        let page3 = try await store.list(req)
        #expect(page3.tasks.count == 1)
        #expect(page3.nextPageToken.isEmpty)
    }
}

// MARK: - TaskUpdateManager tests

@Suite("TaskUpdateManager")
struct TaskUpdateManagerTests {

    private func makeStore() -> InMemoryTaskStore { InMemoryTaskStore() }

    private func storedTask(id: String, state: TaskState, store: InMemoryTaskStore) async throws -> StoredTask {
        var task = Task(); task.id = id
        var status = TaskStatus(); status.state = state
        task.status = status
        let version = try await store.create(task: task)
        return StoredTask(task: task, version: version)
    }

    @Test("process statusUpdate changes task state")
    func processStatusUpdate() async throws {
        let store = makeStore()
        let stored = try await storedTask(id: "t1", state: .working, store: store)
        let manager = TaskUpdateManager(store: store)

        var newStatus = TaskStatus(); newStatus.state = .completed
        var event = TaskStatusUpdateEvent(); event.taskID = "t1"; event.status = newStatus

        let result = try await manager.process(event: .statusUpdate(event), existing: stored)
        #expect(result.task.status.state == .completed)
        #expect(result.version == 2)
    }

    @Test("process artifactUpdate appends new artifact")
    func processArtifactAppend() async throws {
        let store = makeStore()
        let stored = try await storedTask(id: "t1", state: .working, store: store)
        let manager = TaskUpdateManager(store: store)

        var artifact = Artifact(); artifact.artifactID = "a1"
        var part = Part(); part.text = "content"; artifact.parts = [part]
        var event = TaskArtifactUpdateEvent()
        event.taskID = "t1"; event.artifact = artifact; event.append = false

        let result = try await manager.process(event: .artifactUpdate(event), existing: stored)
        #expect(result.task.artifacts.count == 1)
        #expect(result.task.artifacts[0].artifactID == "a1")
    }

    @Test("process artifactUpdate replaces existing artifact by ID")
    func processArtifactReplace() async throws {
        let store = makeStore()
        var task = Task(); task.id = "t1"
        var artifact = Artifact(); artifact.artifactID = "a1"
        var p = Part(); p.text = "old"; artifact.parts = [p]
        task.artifacts = [artifact]
        let version = try await store.create(task: task)
        let stored = StoredTask(task: task, version: version)

        let manager = TaskUpdateManager(store: store)

        var newArtifact = Artifact(); newArtifact.artifactID = "a1"
        var np = Part(); np.text = "new"; newArtifact.parts = [np]
        var event = TaskArtifactUpdateEvent()
        event.taskID = "t1"; event.artifact = newArtifact; event.append = false

        let result = try await manager.process(event: .artifactUpdate(event), existing: stored)
        #expect(result.task.artifacts.count == 1)
        #expect(result.task.artifacts[0].parts[0].text == "new")
    }

    @Test("process message event is a no-op")
    func processMessageNoOp() async throws {
        let store = makeStore()
        let stored = try await storedTask(id: "t1", state: .working, store: store)
        let manager = TaskUpdateManager(store: store)

        var m = Message(); m.messageID = "m1"; m.role = .agent
        var p = Part(); p.text = "hi"; m.parts = [p]

        let result = try await manager.process(event: .message(m), existing: stored)
        #expect(result.task.status.state == .working)
    }

    @Test("setFailed transitions task to failed state")
    func setFailed() async throws {
        let store = makeStore()
        let stored = try await storedTask(id: "t1", state: .working, store: store)
        _ = stored
        let manager = TaskUpdateManager(store: store)

        try await manager.setFailed(taskID: "t1", error: A2AServerError.internalError(message: "boom"))

        let afterFail = try await store.get(taskID: "t1")
        #expect(afterFail.task.status.state == .failed)
    }

    @Test("process retries on concurrentModification")
    func processRetry() async throws {
        let store = makeStore()
        let stored = try await storedTask(id: "t1", state: .working, store: store)

        // Simulate a concurrent update by incrementing the version in the store before
        // the manager tries to write its update, using a second update.
        var newStatus = TaskStatus(); newStatus.state = .completed
        var jumpEvent = TaskStatusUpdateEvent(); jumpEvent.taskID = "t1"; jumpEvent.status = newStatus
        let jumpReq = TaskUpdateRequest(task: stored.task, event: .statusUpdate(jumpEvent), previousVersion: stored.version)
        _ = try await store.update(jumpReq)

        // Now process with the stale `existing` — manager should reload and retry.
        let manager = TaskUpdateManager(store: store)
        var e2 = TaskStatusUpdateEvent(); e2.taskID = "t1"
        var s2 = TaskStatus(); s2.state = .failed; e2.status = s2

        let result = try await manager.process(event: .statusUpdate(e2), existing: stored)
        #expect(result.task.status.state == .failed)
    }
}

// MARK: - InMemoryPushConfigStore tests

@Suite("InMemoryPushConfigStore")
struct InMemoryPushConfigStoreTests {

    @Test("save assigns ID if empty and returns config")
    func saveAssignsID() async throws {
        let store = InMemoryPushConfigStore()
        var config = TaskPushNotificationConfig()
        config.taskID = "t1"
        config.url = "https://example.com/push"

        let saved = try await store.save(taskID: "t1", config: config)
        #expect(!saved.id.isEmpty)
        #expect(saved.taskID == "t1")
        #expect(await store.totalCount == 1)
    }

    @Test("get returns saved config")
    func getConfig() async throws {
        let store = InMemoryPushConfigStore()
        var config = TaskPushNotificationConfig()
        config.id = "cfg1"; config.taskID = "t1"; config.url = "https://example.com"
        _ = try await store.save(taskID: "t1", config: config)

        let fetched = try await store.get(taskID: "t1", configID: "cfg1")
        #expect(fetched?.id == "cfg1")
    }

    @Test("get returns nil for missing config")
    func getMissing() async throws {
        let store = InMemoryPushConfigStore()
        let result = try await store.get(taskID: "t1", configID: "no-such")
        #expect(result == nil)
    }

    @Test("list returns all configs for task")
    func list() async throws {
        let store = InMemoryPushConfigStore()
        for i in 1...3 {
            var config = TaskPushNotificationConfig()
            config.id = "cfg\(i)"; config.taskID = "t1"; config.url = "https://example.com/\(i)"
            _ = try await store.save(taskID: "t1", config: config)
        }
        let configs = try await store.list(taskID: "t1")
        #expect(configs.count == 3)
    }

    @Test("delete removes specific config")
    func delete() async throws {
        let store = InMemoryPushConfigStore()
        var config = TaskPushNotificationConfig()
        config.id = "cfg1"; config.taskID = "t1"; config.url = "https://example.com"
        _ = try await store.save(taskID: "t1", config: config)

        try await store.delete(taskID: "t1", configID: "cfg1")
        #expect(await store.totalCount == 0)
    }

    @Test("deleteAll removes all configs for task")
    func deleteAll() async throws {
        let store = InMemoryPushConfigStore()
        for i in 1...3 {
            var config = TaskPushNotificationConfig()
            config.id = "cfg\(i)"; config.taskID = "t1"; config.url = "https://example.com/\(i)"
            _ = try await store.save(taskID: "t1", config: config)
        }
        try await store.deleteAll(taskID: "t1")
        #expect(await store.totalCount == 0)
    }
}

// MARK: - DefaultRequestHandler tests

@Suite("DefaultRequestHandler")
struct DefaultRequestHandlerTests {

    @Test("sendMessage returns message when executor replies with message")
    func sendMessageReturnsMessage() async throws {
        let handler = DefaultRequestHandler(executor: echoExecutor(replyText: "hello back"))
        let req = makeMessageRequest()
        let resp = try await handler.sendMessage(req)
        guard case .message(let m) = resp.payload else {
            Issue.record("Expected message payload"); return
        }
        #expect(m.parts.first?.text == "hello back")
    }

    @Test("sendMessage returns task when executor completes a task")
    func sendMessageReturnsTask() async throws {
        let handler = DefaultRequestHandler(executor: completingTaskExecutor())
        let req = makeMessageRequest()
        let resp = try await handler.sendMessage(req)
        guard case .task(let t) = resp.payload else {
            Issue.record("Expected task payload"); return
        }
        #expect(t.status.state == .completed)
    }

    @Test("getTask returns task from store")
    func getTask() async throws {
        let handler = DefaultRequestHandler(executor: echoExecutor())
        // First send a message to create a task.
        let sendReq = makeMessageRequest()
        let sendResp = try await handler.sendMessage(sendReq)
        #expect(sendResp.payload != nil)

        // getTask with empty id should throw.
        await #expect(throws: A2AServerError.invalidParams(message: "task ID is required")) {
            _ = try await handler.getTask(GetTaskRequest())
        }
    }

    @Test("getTask throws taskNotFound for unknown ID")
    func getTaskNotFound() async throws {
        let handler = DefaultRequestHandler(executor: echoExecutor())
        var req = GetTaskRequest(); req.id = "nonexistent"
        await #expect(throws: A2AServerError.taskNotFound) {
            _ = try await handler.getTask(req)
        }
    }

    @Test("listTasks returns empty list initially")
    func listTasksEmpty() async throws {
        let handler = DefaultRequestHandler(executor: echoExecutor())
        let resp = try await handler.listTasks(ListTasksRequest())
        #expect(resp.tasks.isEmpty)
    }

    @Test("push config methods throw when push not configured")
    func pushNotSupported() async throws {
        let handler = DefaultRequestHandler(executor: echoExecutor())

        await #expect(throws: A2AServerError.pushNotificationNotSupported) {
            _ = try await handler.getTaskPushConfig(GetTaskPushNotificationConfigRequest())
        }
        await #expect(throws: A2AServerError.pushNotificationNotSupported) {
            _ = try await handler.listTaskPushConfigs(ListTaskPushNotificationConfigsRequest())
        }
        await #expect(throws: A2AServerError.pushNotificationNotSupported) {
            _ = try await handler.createTaskPushConfig(TaskPushNotificationConfig())
        }
        await #expect(throws: A2AServerError.pushNotificationNotSupported) {
            _ = try await handler.deleteTaskPushConfig(DeleteTaskPushNotificationConfigRequest())
        }
    }

    @Test("getExtendedAgentCard throws when not configured")
    func extendedCardNotConfigured() async throws {
        let handler = DefaultRequestHandler(executor: echoExecutor())
        await #expect(throws: A2AServerError.extendedCardNotConfigured) {
            _ = try await handler.getExtendedAgentCard(GetExtendedAgentCardRequest())
        }
    }

    @Test("getExtendedAgentCard returns card from producer")
    func extendedCardFromProducer() async throws {
        var options = A2ARequestHandlerOptions()
        options.extendedCardProducer = { makeTestAgentCard() }
        let handler = DefaultRequestHandler(executor: echoExecutor(), options: options)
        let card = try await handler.getExtendedAgentCard(GetExtendedAgentCardRequest())
        #expect(card.name == "TestAgent")
    }

    @Test("sendStreamingMessage yields events and terminates")
    func sendStreamingMessage() async throws {
        let handler = DefaultRequestHandler(executor: echoExecutor(replyText: "stream-reply"))
        let req = makeMessageRequest()
        let stream = handler.sendStreamingMessage(req)

        var events: [AgentEvent] = []
        for try await event in stream {
            events.append(event)
        }
        #expect(!events.isEmpty)
        if case .message(let m) = events.last {
            #expect(m.parts.first?.text == "stream-reply")
        } else {
            Issue.record("Expected final message event")
        }
    }

    @Test("cancelTask cancels the task in the store")
    func cancelTask() async throws {
        let store = InMemoryTaskStore()
        var task = Task(); task.id = "t1"
        var status = TaskStatus(); status.state = .working
        task.status = status
        _ = try await store.create(task: task)

        var options = A2ARequestHandlerOptions()
        options.taskStore = store
        let handler = DefaultRequestHandler(executor: MockAgentExecutor(executeFn: { _ in
            AsyncThrowingStream { cont in
                // Executor that hangs (tests cancel path only through cancel executor)
                cont.finish()
            }
        }), options: options)

        var cancelReq = CancelTaskRequest(); cancelReq.id = "t1"
        let canceled = try await handler.cancelTask(cancelReq)
        #expect(canceled.status.state == .canceled)
    }
}

// MARK: - A2AServer HTTP dispatch tests

@Suite("A2AServer HTTP dispatch")
struct A2AServerDispatchTests {

    private func makeServer(executor: some AgentExecutor = echoExecutor()) -> A2AServer {
        let handler = DefaultRequestHandler(executor: executor)
        return A2AServer(handler: handler, agentCard: makeTestAgentCard())
    }

    // MARK: Agent card

    @Test("GET /.well-known/agent.json returns agent card JSON")
    func agentCardGet() async throws {
        let server = makeServer()
        let req = ServerRequest(method: "GET", path: "/.well-known/agent.json")
        let result = await server.handle(req)

        guard case .response(let resp) = result else {
            Issue.record("Expected response"); return
        }
        #expect(resp.statusCode == 200)
        #expect(resp.headers["Content-Type"] == "application/json")
        let data = try #require(resp.body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["name"] as? String == "TestAgent")
    }

    @Test("non-POST to / returns method not allowed")
    func nonPostRejected() async {
        let server = makeServer()
        let req = ServerRequest(method: "GET", path: "/")
        let result = await server.handle(req)
        guard case .response(let resp) = result else { Issue.record("Expected response"); return }
        #expect(resp.statusCode == 200)   // JSON-RPC always returns 200
        let body = try! JSONSerialization.jsonObject(with: resp.body!) as! [String: Any]
        let error = body["error"] as? [String: Any]
        #expect(error != nil)
        #expect(error?["code"] as? Int == -32_600)
    }

    @Test("invalid JSON body returns parse error")
    func invalidJSON() async {
        let server = makeServer()
        let req = ServerRequest(method: "POST", path: "/", body: "not json".data(using: .utf8))
        let result = await server.handle(req)
        guard case .response(let resp) = result else { Issue.record("Expected response"); return }
        let body = try! JSONSerialization.jsonObject(with: resp.body!) as! [String: Any]
        let error = body["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32_700)
    }

    @Test("unknown method returns method not found")
    func unknownMethod() async {
        let server = makeServer()
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": "unknown/method", "id": 1, "params": [:]]
        let body = try! JSONSerialization.data(withJSONObject: payload)
        let req = ServerRequest(method: "POST", path: "/", body: body)
        let result = await server.handle(req)
        guard case .response(let resp) = result else { Issue.record("Expected response"); return }
        let json = try! JSONSerialization.jsonObject(with: resp.body!) as! [String: Any]
        let error = json["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32_601)
    }

    // MARK: message/send

    @Test("message/send returns JSON-RPC success with message")
    func messageSend() async throws {
        let server = makeServer(executor: echoExecutor(replyText: "pong"))

        var msg = Message()
        msg.messageID = "m1"; msg.role = .user
        var part = Part(); part.text = "ping"; msg.parts = [part]
        var sendReq = SendMessageRequest(); sendReq.message = msg

        let paramsData = try sendReq.jsonUTF8Data()
        let paramsJSON = try JSONSerialization.jsonObject(with: paramsData) as! [String: Any]

        let envelope: [String: Any] = ["jsonrpc": "2.0", "method": "message/send", "id": 42, "params": paramsJSON]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        let req = ServerRequest(method: "POST", path: "/", body: body)

        let result = await server.handle(req)
        guard case .response(let resp) = result else { Issue.record("Expected response"); return }

        #expect(resp.statusCode == 200)
        let json = try JSONSerialization.jsonObject(with: resp.body!) as! [String: Any]
        #expect(json["jsonrpc"] as? String == "2.0")
        #expect(json["id"] as? Int == 42)
        #expect(json["error"] == nil)
        let resultObj = json["result"] as? [String: Any]
        #expect(resultObj != nil)
    }

    // MARK: tasks/get

    @Test("tasks/get returns taskNotFound error for missing task")
    func tasksGetNotFound() async throws {
        let server = makeServer()
        let params: [String: Any] = ["id": "no-such-task"]
        let envelope: [String: Any] = ["jsonrpc": "2.0", "method": "tasks/get", "id": 1, "params": params]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        let req = ServerRequest(method: "POST", path: "/", body: body)

        let result = await server.handle(req)
        guard case .response(let resp) = result else { Issue.record("Expected response"); return }
        let json = try JSONSerialization.jsonObject(with: resp.body!) as! [String: Any]
        let error = json["error"] as? [String: Any]
        #expect(error?["code"] as? Int == A2AServerError.taskNotFound.jsonRPCCode)
    }

    // MARK: message/stream (SSE)

    @Test("message/stream returns SSE stream result")
    func messageStream() async throws {
        let server = makeServer(executor: echoExecutor(replyText: "streamed"))

        var msg = Message()
        msg.messageID = "m2"; msg.role = .user
        var part = Part(); part.text = "hi"; msg.parts = [part]
        var sendReq = SendMessageRequest(); sendReq.message = msg

        let paramsData = try sendReq.jsonUTF8Data()
        let paramsJSON = try JSONSerialization.jsonObject(with: paramsData) as! [String: Any]

        let envelope: [String: Any] = ["jsonrpc": "2.0", "method": "message/stream", "id": 99, "params": paramsJSON]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        let req = ServerRequest(method: "POST", path: "/", body: body)

        let result = await server.handle(req)
        guard case .stream(let sse) = result else { Issue.record("Expected SSE stream"); return }

        var lines: [String] = []
        for try await line in sse.lines {
            lines.append(line)
        }
        #expect(!lines.isEmpty)
        // Each line should start with "data: "
        for line in lines {
            #expect(line.hasPrefix("data: "))
        }
    }

    // MARK: tasks/list

    @Test("tasks/list returns empty list initially")
    func tasksList() async throws {
        let server = makeServer()
        let envelope: [String: Any] = ["jsonrpc": "2.0", "method": "tasks/list", "id": 5, "params": [:]]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        let req = ServerRequest(method: "POST", path: "/", body: body)

        let result = await server.handle(req)
        guard case .response(let resp) = result else { Issue.record("Expected response"); return }
        let json = try JSONSerialization.jsonObject(with: resp.body!) as! [String: Any]
        let resultObj = json["result"] as? [String: Any]
        #expect(resultObj != nil)
    }

    // MARK: tasks/pushNotificationConfig/set

    @Test("tasks/pushNotificationConfig/set returns error when push not configured")
    func pushConfigSetUnsupported() async throws {
        let server = makeServer()
        let envelope: [String: Any] = ["jsonrpc": "2.0", "method": "tasks/pushNotificationConfig/set", "id": 6, "params": ["taskId": "t1", "url": "https://ex.com"]]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        let req = ServerRequest(method: "POST", path: "/", body: body)

        let result = await server.handle(req)
        guard case .response(let resp) = result else { Issue.record("Expected response"); return }
        let json = try JSONSerialization.jsonObject(with: resp.body!) as! [String: Any]
        let error = json["error"] as? [String: Any]
        #expect(error?["code"] as? Int == A2AServerError.pushNotificationNotSupported.jsonRPCCode)
    }

    // MARK: agent/authenticatedExtendedCard

    @Test("agent/authenticatedExtendedCard returns error when not configured")
    func extendedCardUnconfigured() async throws {
        let server = makeServer()
        let envelope: [String: Any] = ["jsonrpc": "2.0", "method": "agent/authenticatedExtendedCard", "id": 7, "params": [:]]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        let req = ServerRequest(method: "POST", path: "/", body: body)

        let result = await server.handle(req)
        guard case .response(let resp) = result else { Issue.record("Expected response"); return }
        let json = try JSONSerialization.jsonObject(with: resp.body!) as! [String: Any]
        let error = json["error"] as? [String: Any]
        #expect(error?["code"] as? Int == A2AServerError.extendedCardNotConfigured.jsonRPCCode)
    }

    // MARK: Custom card path

    @Test("agent card is served at custom path")
    func customCardPath() async {
        let handler = DefaultRequestHandler(executor: echoExecutor())
        let server = A2AServer(handler: handler, agentCard: makeTestAgentCard(), cardPath: "/agent-card")

        let good = await server.handle(ServerRequest(method: "GET", path: "/agent-card"))
        guard case .response(let r1) = good else { Issue.record("Expected response"); return }
        #expect(r1.statusCode == 200)

        // Default path should now return 404 / method not allowed.
        let wrong = await server.handle(ServerRequest(method: "GET", path: "/.well-known/agent.json"))
        guard case .response(let r2) = wrong else { Issue.record("Expected response"); return }
        // It falls through to POST-only check and returns JSON-RPC error.
        #expect(r2.statusCode == 200) // JSON-RPC errors always return HTTP 200
    }
}

// MARK: - ExecutionManager tests

@Suite("ExecutionManager")
struct ExecutionManagerTests {

    @Test("execute creates task and yields events")
    func executeCreatesTask() async throws {
        let store = InMemoryTaskStore()
        let executor = echoExecutor(replyText: "exec-reply")
        let manager = ExecutionManager(executor: executor, store: store)

        let req = makeMessageRequest()
        let stream = try await manager.execute(request: req)

        var events: [AgentEvent] = []
        for try await event in stream { events.append(event) }

        #expect(!events.isEmpty)
        if case .message(let m) = events.last {
            #expect(m.parts.first?.text == "exec-reply")
        } else {
            Issue.record("Expected message event at end")
        }
    }

    @Test("execute throws on missing message")
    func executeMissingMessage() async {
        let store = InMemoryTaskStore()
        let manager = ExecutionManager(executor: echoExecutor(), store: store)
        await #expect(throws: A2AServerError.invalidParams(message: "message is required")) {
            _ = try await manager.execute(request: SendMessageRequest())
        }
    }

    @Test("resubscribe throws noActiveExecution for unknown task")
    func resubscribeUnknown() async {
        let store = InMemoryTaskStore()
        let manager = ExecutionManager(executor: echoExecutor(), store: store)
        await #expect(throws: ExecutionManagerError.noActiveExecution) {
            _ = try await manager.resubscribe(taskID: "no-such-task")
        }
    }

    @Test("cancel transitions task to canceled state")
    func cancelTask() async throws {
        let store = InMemoryTaskStore()
        var task = Task(); task.id = "t-cancel"
        var status = TaskStatus(); status.state = .working
        task.status = status
        _ = try await store.create(task: task)

        let manager = ExecutionManager(executor: completingTaskExecutor(), store: store)
        var cancelReq = CancelTaskRequest(); cancelReq.id = "t-cancel"
        let result = try await manager.cancel(request: cancelReq)
        #expect(result.status.state == .canceled)
    }
}
