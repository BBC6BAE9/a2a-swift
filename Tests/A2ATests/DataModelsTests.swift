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
import SwiftProtobuf
@testable import A2A
// MARK: - Data Models Tests
// Tests proto-generated types using SwiftProtobuf JSON round-trips.

@Suite("Data Models")
struct DataModelsTests {

    // MARK: AgentCard

    @Test("AgentCard can be serialized and deserialized via SwiftProtobuf JSON")
    func agentCardRoundTrip() throws {
        var agentCard = AgentCard()
        agentCard.name = "Test Agent"
        agentCard.description_p = "An agent for testing"
        agentCard.version = "1.0.0"

        let jsonData = try agentCard.jsonUTF8Data()
        let decoded = try AgentCard(jsonUTF8Data: jsonData)

        #expect(decoded == agentCard)
        #expect(decoded.name == "Test Agent")
    }

    // MARK: Message

    @Test("Message can be serialized and deserialized via SwiftProtobuf JSON")
    func messageRoundTrip() throws {
        var part = Part()
        part.text = "Hello, agent!"

        var message = Message()
        message.messageID = "12345"
        message.role = .user
        message.parts = [part]

        let jsonData = try message.jsonUTF8Data()
        let decoded = try Message(jsonUTF8Data: jsonData)

        #expect(decoded == message)
        #expect(decoded.role == .user)
        #expect(decoded.messageID == "12345")
    }

    @Test("Message with empty parts can be serialized and deserialized")
    func messageEmptyPartsRoundTrip() throws {
        var message = Message()
        message.messageID = "12345"
        message.role = .user

        let jsonData = try message.jsonUTF8Data()
        let decoded = try Message(jsonUTF8Data: jsonData)

        #expect(decoded == message)
    }

    @Test("Message with multiple parts can be serialized and deserialized")
    func messageMultiplePartsRoundTrip() throws {
        var textPart = Part()
        textPart.text = "Hello"

        var urlPart = Part()
        urlPart.url = "file:///path/to/file.txt"
        urlPart.mediaType = "text/plain"

        var rawPart = Part()
        rawPart.raw = Data("hello".utf8)

        var message = Message()
        message.messageID = "12345"
        message.role = .user
        message.parts = [textPart, urlPart, rawPart]

        let jsonData = try message.jsonUTF8Data()
        let decoded = try Message(jsonUTF8Data: jsonData)

        #expect(decoded == message)
        #expect(decoded.parts.count == 3)
    }

    // MARK: Task

    @Test("Task can be serialized and deserialized via SwiftProtobuf JSON")
    func taskRoundTrip() throws {
        var status = TaskStatus()
        status.state = .working

        var artifact = Artifact()
        artifact.artifactID = "artifact-1"
        var artifactPart = Part()
        artifactPart.text = "Hello"
        artifact.parts = [artifactPart]

        var task = Task()
        task.id = "task-123"
        task.contextID = "context-456"
        task.status = status
        task.artifacts = [artifact]

        let jsonData = try task.jsonUTF8Data()
        let decoded = try Task(jsonUTF8Data: jsonData)

        #expect(decoded == task)
        #expect(decoded.id == "task-123")
        #expect(decoded.contextID == "context-456")
    }

    @Test("Task with minimal fields can be serialized and deserialized")
    func taskMinimalRoundTrip() throws {
        var status = TaskStatus()
        status.state = .working

        var task = Task()
        task.id = "task-123"
        task.contextID = "context-456"
        task.status = status

        let jsonData = try task.jsonUTF8Data()
        let decoded = try Task(jsonUTF8Data: jsonData)

        #expect(decoded == task)
    }

    // MARK: Part

    @Test("Part text can be serialized and deserialized")
    func partTextRoundTrip() throws {
        var part = Part()
        part.text = "Hello"

        let jsonData = try part.jsonUTF8Data()
        let decoded = try Part(jsonUTF8Data: jsonData)

        #expect(decoded == part)
        if case .text(let t) = decoded.content {
            #expect(t == "Hello")
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("Part url can be serialized and deserialized")
    func partUrlRoundTrip() throws {
        var part = Part()
        part.url = "file:///path/to/file.txt"
        part.mediaType = "text/plain"

        let jsonData = try part.jsonUTF8Data()
        let decoded = try Part(jsonUTF8Data: jsonData)

        #expect(decoded == part)
    }

    @Test("Part raw bytes can be serialized and deserialized")
    func partRawRoundTrip() throws {
        var part = Part()
        part.raw = Data("hello".utf8)
        part.filename = "hello.txt"

        let jsonData = try part.jsonUTF8Data()
        let decoded = try Part(jsonUTF8Data: jsonData)

        #expect(decoded == part)
    }

    // MARK: TaskPushNotificationConfig

    @Test("TaskPushNotificationConfig can be serialized and deserialized")
    func taskPushNotificationConfigRoundTrip() throws {
        var config = TaskPushNotificationConfig()
        config.taskID = "task-123"
        config.id = "config-1"
        config.url = "https://example.com/push"

        let jsonData = try config.jsonUTF8Data()
        let decoded = try TaskPushNotificationConfig(jsonUTF8Data: jsonData)

        #expect(decoded == config)
        #expect(decoded.taskID == "task-123")
    }
}
