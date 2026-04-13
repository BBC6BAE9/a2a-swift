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

import Testing
import Foundation
@testable import A2A
// MARK: - A2AClient Tests
// Mirrors Dart `test/a2a/client/a2a_client_test.dart`

@Suite("A2AClient")
struct A2AClientTests {

    @Test("getAgentCard returns an AgentCard on success")
    func getAgentCardSuccess() async throws {
        let agentCardDict: [String: Any] = [
            "name": "Test Agent",
            "description": "A test agent.",
            "version": "1.0.0",
            "capabilities": [
                "streaming": false,
                "pushNotifications": false,
            ] as [String: Any],
        ]
        let transport = FakeTransport(response: agentCardDict)
        let client = A2AClient(url: "http://localhost:8080", transport: transport)
        let result = try await client.getAgentCard()
        #expect(result.name == "Test Agent")
    }

    @Test("messageSend returns a Task on success")
    func messageSendSuccess() async throws {
        // SendMessageResponse with a task payload
        let taskDict: [String: Any] = [
            "task": [
                "id": "123",
                "contextId": "456",
                "status": ["state": "TASK_STATE_SUBMITTED"] as [String: Any],
            ] as [String: Any],
        ]
        let transport = FakeTransport(response: ["result": taskDict])
        let client = A2AClient(url: "http://localhost:8080", transport: transport)
        var message = Message()
        message.messageID = "1"
        message.role = .user
        var part = Part()
        part.text = "Hello"
        message.parts = [part]
        let result = try await client.messageSend(message)
        #expect(result.task.id == "123")
    }

    @Test("messageStream returns a stream of StreamResponse on success")
    func messageStreamSuccess() async throws {
        let transport = FakeTransport()
        let client = A2AClient(url: "http://localhost:8080", transport: transport)

        // Proto JSON: StreamResponse with statusUpdate payload
        let eventDict: [String: Any] = [
            "statusUpdate": [
                "taskId": "123",
                "contextId": "456",
                "status": ["state": "TASK_STATE_WORKING"] as [String: Any],
            ] as [String: Any],
        ]

        var message = Message()
        message.messageID = "1"
        message.role = .user
        let stream = client.messageStream(message)

        let received = try await drainStream(stream) {
            transport.addEvent(eventDict)
            transport.finishStream()
        }

        #expect(received.count == 1)
        if case .statusUpdate(let update)? = received[0].payload {
            #expect(update.taskID == "123")
        } else {
            Issue.record("Expected statusUpdate, got \(received[0])")
        }
        #expect(transport.streamRequests.count == 1)
        #expect(transport.streamRequests[0]["id"] != nil)
    }

    @Test("request IDs are incremented for each request")
    func requestIdIncrement() async throws {
        // messageSend expects result.task, getTask/cancelTask expect result as a flat Task
        let sendResultDict: [String: Any] = [
            "task": [
                "id": "123",
                "contextId": "456",
                "status": ["state": "TASK_STATE_SUBMITTED"] as [String: Any],
            ] as [String: Any],
        ]
        let taskResultDict: [String: Any] = [
            "id": "123",
            "contextId": "456",
            "status": ["state": "TASK_STATE_SUBMITTED"] as [String: Any],
        ]
        let transport = FakeTransport(responses: [
            ["result": sendResultDict],
            ["result": taskResultDict],
            ["result": taskResultDict],
        ])
        let client = A2AClient(url: "http://localhost:8080", transport: transport)
        var message = Message()
        message.messageID = "1"
        message.role = .user
        _ = try await client.messageSend(message)
        _ = try await client.getTask("123")
        _ = try await client.cancelTask("123")
        #expect(transport.requests.count == 3)
        #expect(transport.requests[0]["id"] as? Int == 0)
        #expect(transport.requests[1]["id"] as? Int == 1)
        #expect(transport.requests[2]["id"] as? Int == 2)
    }

    @Test("messageStream handles task payload in StreamResponse")
    func messageStreamTaskPayload() async throws {
        let transport = FakeTransport()
        let client = A2AClient(url: "http://localhost:8080", transport: transport)
        // Proto JSON: StreamResponse with task payload
        let taskDict: [String: Any] = [
            "task": [
                "id": "123",
                "contextId": "456",
                "status": ["state": "TASK_STATE_WORKING"] as [String: Any],
            ] as [String: Any],
        ]
        var message = Message()
        message.messageID = "1"
        message.role = .user
        let stream = client.messageStream(message)

        let received = try await drainStream(stream) {
            transport.addEvent(taskDict)
            transport.finishStream()
        }

        #expect(received.count == 1)
        if case .task(let task)? = received[0].payload {
            #expect(task.id == "123")
            #expect(task.contextID == "456")
            #expect(task.status.state == .working)
        } else {
            Issue.record("Expected task payload, got \(received[0])")
        }
    }

    @Test("messageStream includes extensions in params if present in message")
    func messageStreamExtensionsInParams() async throws {
        let transport = FakeTransport()
        let client = A2AClient(url: "http://localhost:8080", transport: transport)
        var message = Message()
        message.messageID = "1"
        message.role = .user
        message.extensions = ["ext1", "ext2"]
        let stream = client.messageStream(message)
        // Finish the stream so the consumer loop exits.
        transport.finishStream()
        for try await _ in stream {}

        #expect(transport.streamRequests.count == 1)
        let params = transport.streamRequests[0]["params"] as? [String: Any]
        #expect(params?["extensions"] as? [String] == ["ext1", "ext2"])
    }

    @Test("messageStream handles statusUpdate payload in StreamResponse")
    func messageStreamStatusUpdatePayload() async throws {
        let transport = FakeTransport()
        let client = A2AClient(url: "http://localhost:8080", transport: transport)
        // Proto JSON: StreamResponse with statusUpdate payload
        let statusUpdateDict: [String: Any] = [
            "statusUpdate": [
                "taskId": "123",
                "contextId": "456",
                "status": ["state": "TASK_STATE_WORKING"] as [String: Any],
            ] as [String: Any],
        ]
        var message = Message()
        message.messageID = "1"
        message.role = .user
        let stream = client.messageStream(message)

        let received = try await drainStream(stream) {
            transport.addEvent(statusUpdateDict)
            transport.finishStream()
        }

        #expect(received.count == 1)
        if case .statusUpdate(let update)? = received[0].payload {
            #expect(update.taskID == "123")
            #expect(update.contextID == "456")
            #expect(update.status.state == .working)
        } else {
            Issue.record("Expected statusUpdate payload, got \(received[0])")
        }
    }
}

// MARK: - drainStream helper

/// Drains `stream` while concurrently calling `feed()` to supply events.
private func drainStream(
    _ stream: AsyncThrowingStream<StreamResponse, Error>,
    feed: () -> Void
) async throws -> [StreamResponse] {
    var events: [StreamResponse] = []
    let consumeTask = _Concurrency.Task {
        var collected: [StreamResponse] = []
        for try await e in stream { collected.append(e) }
        return collected
    }
    feed()
    events = try await consumeTask.value
    return events
}
