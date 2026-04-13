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
// MARK: - Example end-to-end test
// Mirrors Dart `test/a2a/example_test.dart`

@Suite("Example")
struct ExampleTests {

    @Test("example client and server – countdown then liftoff")
    func countdownLiftoff() async throws {
        let transport = FakeTransport()
        let client = A2AClient(url: "http://localhost/", transport: transport)
        defer { client.close() }

        var message = Message()
        message.messageID = UUID().uuidString
        message.role = .user
        var startPart = Part()
        startPart.text = "start 10"
        message.parts = [startPart]

        let stream = client.messageStream(message)

        var collectedTexts: [String] = []
        var taskId: String?

        // Feed all events before draining (FakeTransport queues events added
        // before sendStream is called, then flushes them when the stream is consumed).
        // Proto JSON: StreamResponse with statusUpdate payload
        transport.addEvent([
            "statusUpdate": [
                "taskId": "task-123",
                "contextId": "context-123",
                "status": ["state": "TASK_STATE_WORKING"] as [String: Any],
            ] as [String: Any],
        ])

        for i in stride(from: 10, through: 0, by: -1) {
            // Proto JSON: StreamResponse with artifactUpdate payload
            transport.addEvent([
                "artifactUpdate": [
                    "taskId": "task-123",
                    "contextId": "context-123",
                    "artifact": [
                        "artifactId": "artifact-\(i)",
                        "parts": [["text": "Countdown at \(i)!"] as [String: Any]],
                    ] as [String: Any],
                    "append": false,
                    "lastChunk": i == 0,
                ] as [String: Any],
            ])
        }

        transport.addEvent([
            "statusUpdate": [
                "taskId": "task-123",
                "contextId": "context-123",
                "status": ["state": "TASK_STATE_COMPLETED"] as [String: Any],
            ] as [String: Any],
        ])

        transport.addEvent([
            "artifactUpdate": [
                "taskId": "task-123",
                "contextId": "context-123",
                "artifact": [
                    "artifactId": "artifact-liftoff",
                    "parts": [["text": "Liftoff!"] as [String: Any]],
                ] as [String: Any],
                "append": false,
                "lastChunk": true,
            ] as [String: Any],
        ])

        transport.finishStream()

        // Drain stream.
        for try await event in stream {
            if taskId == nil {
                switch event.payload {
                case .statusUpdate(let update): taskId = update.taskID
                case .artifactUpdate(let update): taskId = update.taskID
                case .task(let task): taskId = task.id
                case .message(let msg): taskId = msg.taskID
                case .none: break
                }
            }
            if case .artifactUpdate(let update)? = event.payload {
                for part in update.artifact.parts {
                    if case .text(let text) = part.content {
                        collectedTexts.append(text)
                        if text.contains("Countdown at 5") {
                            var pauseMessage = Message()
                            pauseMessage.messageID = UUID().uuidString
                            pauseMessage.role = .user
                            pauseMessage.taskID = taskId ?? ""
                            var pausePart = Part()
                            pausePart.text = "pause"
                            pauseMessage.parts = [pausePart]
                            _ = try? await client.messageSend(pauseMessage)
                        }
                    }
                }
            }
        }

        let joined = collectedTexts.joined(separator: "\n")
        #expect(joined.contains("Countdown at 5!"))
        #expect(joined.contains("Liftoff!"))
    }
}
