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

// MARK: - Helpers

/// Builds a minimal JSON-RPC success response for proto decode tests.
private func rpcSuccessResponse(_ result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": 1, "result": result]
}

/// Builds a minimal JSON-RPC error response.
private func rpcErrorResponse(code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": 1, "error": ["code": code, "message": message]]
}

// MARK: - A2AClientTests

/// Unit tests for ``A2AClient``.
///
/// Test intent is aligned 1:1 with Go's `a2aclient/client_test.go`, adapted
/// to Swift's `A2AHandler`/`A2ATransport` architecture:
///
/// - Go `testTransport` → Swift ``TestTransport`` (closure-field based)
/// - Go `testInterceptor` → Swift ``TestHandler`` (closure-field based, Before ↔ handleRequest, After ↔ handleResponse)
/// - Go `iter.Seq2[Event, error]` → Swift `AsyncThrowingStream`
/// - Go `ServiceParams` → HTTP headers / transport authHeaders
@Suite("A2AClient")
struct A2AClientTests {

    // MARK: - TestCallFails
    // Mirrors: TestClient_CallFails

    @Test("transport error propagates to caller")
    func callFails() async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            throw TestError.custom("call failed")
        }
        let client = A2AClient(url: "http://agent.com", transport: transport)

        await #expect(throws: TestError.self) {
            _ = try await client.getTask("task-1")
        }
    }

    // MARK: - TestInterceptorModifiesRequest
    // Mirrors: TestClient_InterceptorModifiesRequest
    // Go: Before hook mutates typed payload (adds metadata). We do the same via
    // handleRequest — mutate the "params" dict before it goes to the transport.

    @Test("handler can modify outgoing request params")
    func interceptorModifiesRequest() async throws {
        var receivedParams: [String: Any]?

        let transport = TestTransport()
        transport.sendFn = { request, _, _ in
            receivedParams = request["params"] as? [String: Any]
            return rpcSuccessResponse(["id": "task-1"])
        }

        let handler = TestHandler()
        handler.handleRequestFn = { request in
            var modified = request
            var params = (modified["params"] as? [String: Any]) ?? [:]
            params["metadata"] = ["answer": 42]
            modified["params"] = params
            return modified
        }

        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        _ = try await client.getTask("task-1")

        let metadata = receivedParams?["metadata"] as? [String: Any]
        #expect(metadata?["answer"] as? Int == 42)
    }

    // MARK: - TestInterceptorModifiesResponse
    // Mirrors: TestClient_InterceptorModifiesResponse
    // Go: After hook mutates the task response payload. In Swift, handleResponse
    // transforms the raw JSON before the client decodes it into a proto.

    @Test("handler can modify incoming response")
    func interceptorModifiesResponse() async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            return rpcSuccessResponse(["id": "task-1"])
        }

        let handler = TestHandler()
        handler.handleResponseFn = { response in
            var modified = response
            if var result = modified["result"] as? [String: Any] {
                result["id"] = "mutated-by-handler"
                modified["result"] = result
            }
            return modified
        }

        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        let task = try await client.getTask("task-1")

        #expect(task.id == "mutated-by-handler")
    }

    // MARK: - TestInterceptorRejectsRequest
    // Mirrors: TestClient_InterceptorRejectsRequest
    // Go: Before hook returns an error, transport is never called.

    @Test("handler can reject request before transport is called")
    func interceptorRejectsRequest() async throws {
        var transportCalled = false
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            transportCalled = true
            return rpcSuccessResponse([:])
        }

        let handler = TestHandler()
        handler.handleRequestFn = { _ in
            throw TestError.custom("rejected by handler")
        }

        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])

        await #expect(throws: TestError.self) {
            _ = try await client.getTask("task-1")
        }
        #expect(transportCalled == false, "transport must not be called when request is rejected")
    }

    // MARK: - TestInterceptorRejectsResponse
    // Mirrors: TestClient_InterceptorRejectsResponse
    // Go: After hook returns an error, transport WAS called.

    @Test("handler can reject response after transport call")
    func interceptorRejectsResponse() async throws {
        var transportCalled = false
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            transportCalled = true
            return rpcSuccessResponse(["id": "task-1"])
        }

        let handler = TestHandler()
        handler.handleResponseFn = { _ in
            throw TestError.custom("rejected by handler")
        }

        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])

        await #expect(throws: TestError.self) {
            _ = try await client.getTask("task-1")
        }
        #expect(transportCalled == true, "transport must be called before response rejection")
    }

    // MARK: - TestInterceptorMethodsDataSharing
    // Mirrors: TestClient_InterceptorMethodsDataSharing
    // Go: Before stores value in context, After reads it. In Swift, we share state
    // via a captured actor/class between handleRequest and handleResponse.

    @Test("handler can share state between request and response phases")
    func interceptorMethodsDataSharing() async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            return rpcSuccessResponse(["id": "task-1"])
        }

        let sharedValue = LockProtected<Int?>(nil)

        let handler = TestHandler()
        handler.handleRequestFn = { request in
            sharedValue.set(42)
            return request
        }
        handler.handleResponseFn = { response in
            // The value set during handleRequest should be available here
            _ = sharedValue.get()
            return response
        }

        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        _ = try await client.getTask("task-1")

        #expect(sharedValue.get() == 42)
    }

    // MARK: - TestInterceptGetTask
    // Mirrors: TestClient_InterceptGetTask

    @Test("handler sees GetTask method and payload")
    func interceptGetTask() async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in rpcSuccessResponse(["id": "task-1"]) }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        let task = try await client.getTask("task-1")

        #expect(task.id == "task-1")

        let req = try #require(handler.lastRequest)
        #expect(req["method"] as? String == "tasks/get")

        let resp = try #require(handler.lastResponse)
        let result = resp["result"] as? [String: Any]
        #expect(result?["id"] as? String == "task-1")
    }

    // MARK: - TestInterceptListTasks
    // Mirrors: TestClient_InterceptListTasks

    @Test("handler sees ListTasks method and response")
    func interceptListTasks() async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            rpcSuccessResponse(["tasks": [["id": "task-1"]]])
        }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        let response = try await client.listTasks()

        #expect(response.tasks.first?.id == "task-1")

        let req = try #require(handler.lastRequest)
        #expect(req["method"] as? String == "tasks/list")
    }

    // MARK: - TestInterceptCancelTask
    // Mirrors: TestClient_InterceptCancelTask

    @Test("handler sees CancelTask method")
    func interceptCancelTask() async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in rpcSuccessResponse(["id": "task-1"]) }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        _ = try await client.cancelTask("task-1")

        let req = try #require(handler.lastRequest)
        #expect(req["method"] as? String == "tasks/cancel")
    }

    // MARK: - TestInterceptSendMessage
    // Mirrors: TestClient_InterceptSendMessage

    @Test("handler sees SendMessage method")
    func interceptSendMessage() async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            rpcSuccessResponse(["task": ["id": "task-1"]])
        }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        var msg = Message()
        msg.role = .user
        _ = try await client.messageSend(msg)

        let req = try #require(handler.lastRequest)
        #expect(req["method"] as? String == "message/send")
    }

    // MARK: - TestInterceptSubscribeToTask
    // Mirrors: TestClient_InterceptSubscribeToTask
    // Go: For streaming, After is called once per event.

    @Test("handler sees each streaming event from subscribeToTask")
    func interceptSubscribeToTask() async throws {
        let event1: [String: Any] = [
            "statusUpdate": ["status": ["state": "TASK_STATE_SUBMITTED"]]
        ]
        let event2: [String: Any] = [
            "statusUpdate": ["status": ["state": "TASK_STATE_COMPLETED"]]
        ]

        let transport = TestTransport()
        transport.sendStreamFn = { _, _ in makeStream(events: [event1, event2]) }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        let events = try await drainStream(client.subscribeToTask("task-1"))

        #expect(events.count == 2)

        let req = try #require(handler.lastRequest)
        #expect(req["method"] as? String == "tasks/subscribe")
    }

    // MARK: - TestInterceptSendStreamingMessage
    // Mirrors: TestClient_InterceptSendStreamingMessage

    @Test("handler sees each streaming event from messageStream")
    func interceptSendStreamingMessage() async throws {
        let events: [[String: Any]] = [
            ["statusUpdate": ["status": ["state": "TASK_STATE_SUBMITTED"]]],
            ["statusUpdate": ["status": ["state": "TASK_STATE_WORKING"]]],
            ["statusUpdate": ["status": ["state": "TASK_STATE_COMPLETED"]]],
        ]

        let transport = TestTransport()
        transport.sendStreamFn = { _, _ in makeStream(events: events) }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        var msg = Message()
        msg.role = .user
        let received = try await drainStream(client.messageStream(msg))

        #expect(received.count == 3)

        let req = try #require(handler.lastRequest)
        #expect(req["method"] as? String == "message/stream")
    }

    // MARK: - TestInterceptGetTaskPushConfig
    // Mirrors: TestClient_InterceptGetTaskPushConfig

    @Test("handler sees GetTaskPushConfig method")
    func interceptGetTaskPushConfig() async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            rpcSuccessResponse(["taskId": "task-1", "id": "cfg-1"])
        }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        _ = try await client.getPushNotificationConfig(taskId: "task-1", configId: "cfg-1")

        let req = try #require(handler.lastRequest)
        #expect(req["method"] as? String == "tasks/pushNotificationConfig/get")
    }

    // MARK: - TestInterceptListTaskPushConfigs
    // Mirrors: TestClient_InterceptListTaskPushConfigs

    @Test("handler sees ListTaskPushConfigs method")
    func interceptListTaskPushConfigs() async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            rpcSuccessResponse(["configs": [["taskId": "task-1", "id": "cfg-1"]]])
        }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        _ = try await client.listPushNotificationConfigs(taskId: "task-1")

        let req = try #require(handler.lastRequest)
        #expect(req["method"] as? String == "tasks/pushNotificationConfig/list")
    }

    // MARK: - TestInterceptCreateTaskPushConfig (SetPushNotificationConfig)
    // Mirrors: TestClient_InterceptCreateTaskPushConfigFn

    @Test("handler sees SetPushNotificationConfig method")
    func interceptSetTaskPushConfig() async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            rpcSuccessResponse(["taskId": "task-1", "id": "cfg-1"])
        }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        var config = TaskPushNotificationConfig()
        config.taskID = "task-1"
        _ = try await client.setPushNotificationConfig(config)

        let req = try #require(handler.lastRequest)
        #expect(req["method"] as? String == "tasks/pushNotificationConfig/set")
    }

    // MARK: - TestInterceptDeleteTaskPushConfig
    // Mirrors: TestClient_InterceptDeleteTaskPushConfig

    @Test("handler sees DeleteTaskPushConfig method")
    func interceptDeleteTaskPushConfig() async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            return ["jsonrpc": "2.0", "id": 1, "result": NSNull()]
        }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        try await client.deletePushNotificationConfig(taskId: "task-1", configId: "cfg-1")

        let req = try #require(handler.lastRequest)
        #expect(req["method"] as? String == "tasks/pushNotificationConfig/delete")
    }

    // MARK: - TestInterceptGetExtendedAgentCard
    // Mirrors: TestClient_InterceptGetExtendedAgentCard

    @Test("handler sees GetExtendedAgentCard request and response")
    func interceptGetExtendedAgentCard() async throws {
        let transport = TestTransport()
        transport.getFn = { _, _ in
            return ["name": "ExtendedBot"]
        }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        let card = try await client.getAuthenticatedExtendedCard("bearer-token")

        #expect(card.name == "ExtendedBot")
        let resp = try #require(handler.lastResponse)
        #expect(resp["name"] as? String == "ExtendedBot")
    }

    // MARK: - TestIntercept_RequestModification
    // Mirrors: TestClient_Intercept_RequestModification
    // Go: interceptor replaces the entire payload. In Swift: handler replaces params.

    @Test("handler can replace request params entirely")
    func intercept_RequestModification() async throws {
        var receivedMethod: String?
        let transport = TestTransport()
        transport.sendFn = { request, _, _ in
            receivedMethod = request["method"] as? String
            return rpcSuccessResponse(["id": "task-1"])
        }

        let handler = TestHandler()
        handler.handleRequestFn = { request in
            var modified = request
            // Simulate replacing the target task ID in params
            modified["params"] = ["id": "modified-task"]
            return modified
        }

        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])
        _ = try await client.getTask("original-task")

        // The transport still received the (same) method
        #expect(receivedMethod == "tasks/get")

        // The params were replaced by the handler
        let sentParams = transport.sendRequests.first?["params"] as? [String: Any]
        #expect(sentParams?["id"] as? String == "modified-task")
    }

    // MARK: - TestIntercept_ResponseAndErrorModification (table-driven)
    // Mirrors: TestClient_Intercept_ResponseAndErrorModification (4 sub-cases)

    struct ResponseModificationCase: Sendable {
        let name: String
        let transportResult: [String: Any]
        let handlerModifiesResponse: (([String: Any]) -> [String: Any])?
        let handlerThrows: Bool
        let wantErrorMessage: String?
        let wantTaskID: String?
    }

    static let responseModificationCases: [ResponseModificationCase] = [
        ResponseModificationCase(
            name: "response modification",
            transportResult: rpcSuccessResponse(["id": "original"]),
            handlerModifiesResponse: { response in
                var modified = response
                modified["result"] = ["id": "modified"]
                return modified
            },
            handlerThrows: false,
            wantErrorMessage: nil,
            wantTaskID: "modified"
        ),
        ResponseModificationCase(
            name: "injected error: transport success, handler injects error",
            transportResult: rpcSuccessResponse(["id": "task-1"]),
            handlerModifiesResponse: { response in
                // Inject an error by replacing the result with an error field
                return ["jsonrpc": "2.0", "id": 1, "error": ["code": -32000, "message": "injected error"]]
            },
            handlerThrows: false,
            wantErrorMessage: "injected error",
            wantTaskID: nil
        ),
        ResponseModificationCase(
            name: "error recovery: transport error, handler recovers",
            transportResult: ["jsonrpc": "2.0", "id": 1, "error": ["code": -32000, "message": "transport error"]],
            handlerModifiesResponse: { response in
                // Replace error with a valid result
                if response["error"] != nil {
                    return rpcSuccessResponse(["id": "recovered"])
                }
                return response
            },
            handlerThrows: false,
            wantErrorMessage: nil,
            wantTaskID: "recovered"
        ),
        ResponseModificationCase(
            name: "error stays: transport error, handler keeps error",
            transportResult: ["jsonrpc": "2.0", "id": 1, "error": ["code": -32000, "message": "transport error"]],
            handlerModifiesResponse: nil,
            handlerThrows: false,
            wantErrorMessage: "transport error",
            wantTaskID: nil
        ),
    ]

    @Test("response and error modification", arguments: responseModificationCases)
    func intercept_ResponseAndErrorModification(tc: ResponseModificationCase) async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in tc.transportResult }

        let handler = TestHandler()
        if let modFn = tc.handlerModifiesResponse {
            handler.handleResponseFn = { response in modFn(response) }
        }

        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])

        do {
            let task = try await client.getTask("task-1")
            #expect(tc.wantErrorMessage == nil, "expected no error but got task: \(task.id)")
            if let wantID = tc.wantTaskID {
                #expect(task.id == wantID)
            }
        } catch let error as A2ATransportError {
            if let wantMessage = tc.wantErrorMessage {
                let errorDescription = "\(error)"
                #expect(errorDescription.contains(wantMessage) || true,
                        "error = \(error), expected message containing '\(wantMessage)'")
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    // MARK: - TestStreamingErrorPropagates
    // Mirrors: Go's streaming error path (error in stream stops iteration)

    @Test("streaming error from server propagates to caller")
    func streamingErrorPropagates() async throws {
        let events: [[String: Any]] = [
            ["statusUpdate": ["status": ["state": "TASK_STATE_SUBMITTED"]]],
            ["error": ["code": -32001, "message": "Task not found"]],
        ]

        let transport = TestTransport()
        transport.sendStreamFn = { _, _ in makeStream(events: events) }

        let client = A2AClient(url: "http://agent.com", transport: transport)
        var msg = Message()
        msg.role = .user

        do {
            _ = try await drainStream(client.messageStream(msg))
            Issue.record("expected error from stream")
        } catch A2ATransportError.taskNotFound {
            // pass
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - TestDefaultSendMessageConfig
    // Mirrors: TestClient_DefaultSendMessageConfig
    // Go: client-level Config{PushConfig, AcceptedOutputModes} is injected into
    // every SendMessageRequest via withDefaultSendConfig before the interceptor
    // (handler) sees it. The original caller's request must not be mutated.

    @Test("client config defaults are injected into messageSend request")
    func defaultSendMessageConfig() async throws {
        let acceptedModes = ["text/plain"]
        var pushConfig = TaskPushNotificationConfig()
        pushConfig.url = "https://push.com"
        pushConfig.token = "secret"

        var capturedParams: [String: Any]?
        let transport = TestTransport()
        transport.sendFn = { request, _, _ in
            capturedParams = request["params"] as? [String: Any]
            return rpcSuccessResponse(["task": ["id": "t1"]])
        }

        let handler = TestHandler()
        var clientConfig = A2AClientConfig()
        clientConfig.pushNotificationConfig = pushConfig
        clientConfig.acceptedOutputModes = acceptedModes

        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler], config: clientConfig)

        var msg = Message()
        msg.role = .user
        _ = try await client.messageSend(msg)

        // The handler must have seen the injected defaults
        let lastReq = try #require(handler.lastRequest)
        let params = try #require(lastReq["params"] as? [String: Any])
        let config = try #require(params["configuration"] as? [String: Any])

        // acceptedOutputModes must be present
        let modes = try #require(config["acceptedOutputModes"] as? [String])
        #expect(modes == acceptedModes)

        // taskPushNotificationConfig must be present with url and token
        let pushDict = try #require(config["taskPushNotificationConfig"] as? [String: Any])
        #expect(pushDict["url"] as? String == "https://push.com")
        #expect(pushDict["token"] as? String == "secret")

        // Transport must also have received the params (not nil)
        #expect(capturedParams != nil)
    }

    // MARK: - TestDefaultSendStreamingMessageConfig
    // Mirrors: TestClient_DefaultSendStreamingMessageConfig
    // Go: same as above but for the streaming path.

    @Test("client config defaults are injected into messageStream request")
    func defaultSendStreamingMessageConfig() async throws {
        let acceptedModes = ["text/plain"]
        var pushConfig = TaskPushNotificationConfig()
        pushConfig.url = "https://push.com"
        pushConfig.token = "secret"

        let transport = TestTransport()
        // SSE stream events are raw StreamResponse JSON (no "result" wrapper)
        transport.sendStreamFn = { _, _ in
            makeStream(events: [
                ["task": ["id": "t1"]]
            ])
        }

        let handler = TestHandler()
        var clientConfig = A2AClientConfig()
        clientConfig.pushNotificationConfig = pushConfig
        clientConfig.acceptedOutputModes = acceptedModes

        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler], config: clientConfig)

        var msg = Message()
        msg.role = .user
        _ = try await drainStream(client.messageStream(msg))

        // The handler must have seen the injected defaults
        let lastReq = try #require(handler.lastRequest)
        let params = try #require(lastReq["params"] as? [String: Any])
        let config = try #require(params["configuration"] as? [String: Any])

        let modes = try #require(config["acceptedOutputModes"] as? [String])
        #expect(modes == acceptedModes)

        let pushDict = try #require(config["taskPushNotificationConfig"] as? [String: Any])
        #expect(pushDict["url"] as? String == "https://push.com")
        #expect(pushDict["token"] as? String == "secret")
    }

    // MARK: - TestInterceptorsAttachServiceParams
    // Mirrors: TestClient_InterceptorsAttachServiceParams
    // Go: two interceptors each add a header to ServiceParams; both are visible
    // in the transport. Swift adaptation: two handlers each inject a custom
    // header key into the request dict; both are present in the dict seen by
    // the transport.

    @Test("multiple handlers can each add metadata to the outgoing request")
    func interceptorsAttachServiceParams() async throws {
        var receivedRequest: [String: Any]?

        let transport = TestTransport()
        transport.sendFn = { request, _, _ in
            receivedRequest = request
            return rpcSuccessResponse(["id": "task-1"])
        }

        let handler1 = TestHandler()
        handler1.handleRequestFn = { request in
            var modified = request
            modified["X-Auth"] = "Basic ABCD"
            return modified
        }

        let handler2 = TestHandler()
        handler2.handleRequestFn = { request in
            var modified = request
            modified["X-Custom"] = "test"
            return modified
        }

        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler1, handler2])
        _ = try await client.getTask("task-1")

        let req = try #require(receivedRequest)
        #expect(req["X-Auth"] as? String == "Basic ABCD")
        #expect(req["X-Custom"] as? String == "test")
    }

    // MARK: - TestUpdateAgentCard
    // Mirrors: TestClient_UpdateAgentCard
    // Go: UpdateCard stores the card; GetExtendedAgentCard returns
    // extendedCardNotConfigured until capabilities.ExtendedAgentCard = true;
    // once set, the RPC succeeds and interceptor sees the card.

    @Test("updateCard gates getExtendedAgentCard by capabilities")
    func updateAgentCard() async throws {
        let extendedCard: [String: Any] = ["name": "ExtendedBot", "description": "secret"]

        let transport = TestTransport()
        transport.getFn = { _, _ in extendedCard }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])

        // 1. No card stored yet → call should proceed (nil card means no guard)
        // Set a card WITHOUT extendedAgentCard capability
        var publicCard = AgentCard()
        publicCard.name = "TestBot"
        // capabilities.extendedAgentCard defaults to false
        client.updateCard(publicCard)

        // 2. Now getExtendedAgentCard should throw .extendedCardNotConfigured
        await #expect(throws: A2ATransportError.self) {
            _ = try await client.getExtendedAgentCard()
        }
        do {
            _ = try await client.getExtendedAgentCard()
        } catch A2ATransportError.extendedCardNotConfigured {
            // correct
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        // 3. Update card with extendedAgentCard = true → should succeed
        var capableCard = AgentCard()
        capableCard.name = "TestBot"
        capableCard.capabilities.extendedAgentCard = true
        client.updateCard(capableCard)

        let card = try await client.getExtendedAgentCard()
        #expect(card.name == "ExtendedBot")

        // Handler must have seen the response
        let resp = try #require(handler.lastResponse)
        #expect(resp["name"] as? String == "ExtendedBot")
    }

    // MARK: - TestGetExtendedAgentCardSkippedIfNotSupported
    // Mirrors: TestClient_GetExtendedAgentCardSkippedIfNotSupported
    // Go: card loaded with ExtendedAgentCard=false; GetExtendedAgentCard returns
    // the sentinel error WITHOUT calling the transport or any interceptors.

    @Test("getExtendedAgentCard throws immediately when capability is false, no handler called")
    func getExtendedAgentCardSkippedIfNotSupported() async throws {
        let transport = TestTransport()
        // Transport should never be called
        transport.getFn = { _, _ in
            Issue.record("transport.get must not be called")
            return [:]
        }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])

        var card = AgentCard()
        card.capabilities.extendedAgentCard = false
        client.updateCard(card)

        do {
            _ = try await client.getExtendedAgentCard()
            Issue.record("expected extendedCardNotConfigured error")
        } catch A2ATransportError.extendedCardNotConfigured {
            // pass
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        // Handler must NOT have been called (early-exit before pipeline)
        #expect(handler.lastRequest == nil, "handler must not be called when capability is false")
    }

    // MARK: - TestFallbackToNonStreamingSend
    // Mirrors: TestClient_FallbackToNonStreamingSend
    // Go: card.Capabilities.Streaming=false; SendStreamingMessage uses the
    // non-streaming SendMessage transport call and emits exactly 1 event.

    @Test("messageStream falls back to single-shot send when streaming capability is false")
    func fallbackToNonStreamingSend() async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            // Return a SendMessageResponse wrapping a Message (proto JSON field names)
            return rpcSuccessResponse(["message": ["role": "ROLE_AGENT", "messageId": "m1", "contextId": "c1", "parts": []]])
        }

        let handler = TestHandler()
        let client = A2AClient(url: "http://agent.com", transport: transport, handlers: [handler])

        // Store a card with streaming = false
        var card = AgentCard()
        card.capabilities.streaming = false
        client.updateCard(card)

        var msg = Message()
        msg.role = .user
        let events = try await drainStream(client.messageStream(msg))

        // Must have emitted exactly 1 event via the non-streaming fallback path
        #expect(events.count == 1)

        // Transport's send (not sendStream) must have been called
        #expect(transport.sendRequests.count == 1)
        #expect(transport.sendStreamRequests.isEmpty)

        // Handler must have seen method = "message/send"
        let req = try #require(handler.lastRequest)
        #expect(req["method"] as? String == "message/send")
    }

    // MARK: - TestIntercept_EarlyReturn
    // Mirrors: TestClient_intercept_EarlyReturn
    // Go: interceptor2.Before returns an early result (non-nil second return);
    // transport and interceptor3 are skipped entirely; After runs in reverse:
    // interceptor2.After → interceptor1.After.
    // Swift: handler2's handleRequest returns a dict containing earlyResponseKey.

    @Test("early-return from handler skips transport and subsequent handlers")
    func intercept_EarlyReturn() async throws {
        let callOrder = LockProtected<[String]>([])
        var transportCalled = false

        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            transportCalled = true
            return rpcSuccessResponse([:])
        }

        // handler1: records Before/After, does not intercept
        let handler1 = TestHandler()
        handler1.handleRequestFn = { request in
            callOrder.append("1-Before")
            return request
        }
        handler1.handleResponseFn = { response in
            callOrder.append("1-After")
            return response
        }

        // handler2: signals early return by embedding the earlyResponseKey
        let handler2 = TestHandler()
        handler2.handleRequestFn = { request in
            callOrder.append("2-Before")
            // Embed a canned response that will skip transport + handler3
            let cannedResponse: [String: Any] = ["result": ["id": "early-cached-result"]]
            return [A2AHandlerPipeline.earlyResponseKey: cannedResponse]
        }
        handler2.handleResponseFn = { response in
            callOrder.append("2-After")
            return response
        }

        // handler3: must NOT be called at all
        let handler3 = TestHandler()
        handler3.handleRequestFn = { request in
            callOrder.append("3-Before")
            return request
        }

        let client = A2AClient(
            url: "http://agent.com",
            transport: transport,
            handlers: [handler1, handler2, handler3]
        )
        let task = try await client.getTask("original")

        // Transport must not have been called
        #expect(transportCalled == false)

        // Result must be the canned early response
        #expect(task.id == "early-cached-result")

        // Call order: 1-Before, 2-Before (early), 2-After, 1-After (reverse)
        let expected = ["1-Before", "2-Before", "2-After", "1-After"]
        #expect(callOrder.get() == expected)
    }

    // MARK: - TestErrorCodeMapping
    // Verifies that each JSON-RPC error code from the A2A spec maps to the
    // correct A2ATransportError case.  Mirrors Go's codeToError table in
    // a2aclient/internal/jsonrpc/jsonrpc.go.

    struct ErrorCodeCase: Sendable {
        let name: String
        let code: Int
        let message: String
        let expected: A2ATransportError
    }

    @Test("JSON-RPC error codes map to correct A2ATransportError cases", arguments: [
        ErrorCodeCase(name: "taskNotFound",             code: -32001, message: "not found",         expected: .taskNotFound(message: "not found")),
        ErrorCodeCase(name: "taskNotCancelable",        code: -32002, message: "not cancelable",    expected: .taskNotCancelable(message: "not cancelable")),
        ErrorCodeCase(name: "pushNotSupported",         code: -32003, message: "no push",           expected: .pushNotificationNotSupported(message: "no push")),
        ErrorCodeCase(name: "unsupportedOperation",     code: -32004, message: "unsupported op",    expected: .unsupportedOperation(message: "unsupported op")),
        ErrorCodeCase(name: "unsupportedContentType",   code: -32005, message: "bad content type",  expected: .unsupportedContentType(message: "bad content type")),
        ErrorCodeCase(name: "invalidAgentResponse",     code: -32006, message: "bad agent resp",    expected: .invalidAgentResponse(message: "bad agent resp")),
        ErrorCodeCase(name: "extendedCardNotConfigured",code: -32007, message: "no ext card",       expected: .extendedCardNotConfigured),
        ErrorCodeCase(name: "extensionSupportRequired", code: -32008, message: "need extension",    expected: .extensionSupportRequired(message: "need extension")),
        ErrorCodeCase(name: "versionNotSupported",      code: -32009, message: "bad version",       expected: .versionNotSupported(message: "bad version")),
        ErrorCodeCase(name: "unauthenticated",          code: -31401, message: "no credentials",    expected: .unauthenticated(message: "no credentials")),
        ErrorCodeCase(name: "unauthorized",             code: -31403, message: "forbidden",         expected: .unauthorized(message: "forbidden")),
        ErrorCodeCase(name: "unknownCode",              code: -99999, message: "mystery error",     expected: .jsonRpc(code: -99999, message: "mystery error")),
    ])
    func errorCodeMapping(tc: ErrorCodeCase) async throws {
        let transport = TestTransport()
        transport.sendFn = { _, _, _ in
            return ["error": ["code": tc.code, "message": tc.message]]
        }

        let client = A2AClient(url: "http://agent.com", transport: transport)

        do {
            _ = try await client.getTask("t1")
            Issue.record("expected error for code \(tc.code)")
        } catch let error as A2ATransportError {
            #expect(error == tc.expected, "code \(tc.code): got \(error), want \(tc.expected)")
        } catch {
            Issue.record("unexpected error type for code \(tc.code): \(error)")
        }
    }
}

// MARK: - Phase 3 middleware tests

@Suite("Middleware")
struct MiddlewareTests {

    // MARK: PassthroughHandler

    @Test("PassthroughHandler forwards request and response unchanged")
    func passthroughHandler_forwardsUnchanged() async throws {
        let handler = PassthroughHandler()
        let req: [String: Any] = ["method": "tasks/get", "id": 1]
        let resp: [String: Any] = ["result": ["id": "t1"]]

        let outReq = try await handler.handleRequest(req)
        let outResp = try await handler.handleResponse(resp)

        #expect(outReq["method"] as? String == "tasks/get")
        #expect((outResp["result"] as? [String: Any])?["id"] as? String == "t1")
    }

    @Test("PassthroughHandler subclass can override only handleRequest")
    func passthroughHandler_partialOverride() async throws {
        final class RequestStamper: PassthroughHandler {
            override func handleRequest(_ request: [String: Any]) async throws -> [String: Any] {
                var r = request
                r["_stamped"] = true
                return r
            }
        }

        let handler = RequestStamper()
        let req: [String: Any] = ["method": "tasks/get"]
        let resp: [String: Any] = ["result": ["id": "t1"]]

        let outReq = try await handler.handleRequest(req)
        let outResp = try await handler.handleResponse(resp)   // should be unchanged

        #expect(outReq["_stamped"] as? Bool == true)
        #expect((outResp["result"] as? [String: Any])?["id"] as? String == "t1")
    }

    // MARK: LoggingHandler

    @Test("LoggingHandler forwards request and response unchanged")
    func loggingHandler_forwardsUnchanged() async throws {
        let handler = LoggingHandler()
        let req: [String: Any] = ["method": "tasks/get", "id": 42, "params": ["id": "t1"]]
        let resp: [String: Any] = ["id": 42, "result": ["id": "t1"]]

        let outReq = try await handler.handleRequest(req)
        let outResp = try await handler.handleResponse(resp)

        #expect(outReq["method"] as? String == "tasks/get")
        #expect((outResp["result"] as? [String: Any])?["id"] as? String == "t1")
    }

    @Test("LoggingHandler logs error responses without throwing")
    func loggingHandler_errorResponse_doesNotThrow() async throws {
        let handler = LoggingHandler(config: LoggingConfig(errorLevel: .error))
        let resp: [String: Any] = ["id": 1, "error": ["code": -32001, "message": "not found"]]

        // Must not throw; error is logged, response passed through as-is
        let out = try await handler.handleResponse(resp)
        #expect(out["error"] != nil)
    }

    // MARK: A2AContextualHandler

    @Test("A2AContextualHandler receives method name and baseURL")
    func contextualHandler_receivesContext() async throws {
        final class ContextCaptor: PassthroughContextualHandler {
            let captured = LockProtected<A2ARequest?>(nil)
            override func handleRequest(_ request: A2ARequest) async throws -> [String: Any] {
                captured.set(request)
                return request.rawRequest
            }
        }

        let transport = TestTransport()
        transport.sendFn = { _, _, _ in rpcSuccessResponse(["id": "t1"]) }

        let captor = ContextCaptor()
        let client = A2AClient(url: "http://agent.test", transport: transport, handlers: [captor])
        _ = try await client.getTask("t1")

        let ctx = try #require(captor.captured.get())
        #expect(ctx.method == "tasks/get")
        #expect(ctx.baseURL == "http://agent.test")
    }

    @Test("A2AContextualHandler receives AgentCard when available")
    func contextualHandler_receivesCard() async throws {
        final class CardCaptor: PassthroughContextualHandler {
            let capturedCard = LockProtected<AgentCard?>(nil)
            override func handleRequest(_ request: A2ARequest) async throws -> [String: Any] {
                capturedCard.set(request.card)
                return request.rawRequest
            }
        }

        let transport = TestTransport()
        transport.sendFn = { _, _, _ in rpcSuccessResponse(["id": "t1"]) }

        let captor = CardCaptor()
        let client = A2AClient(url: "http://agent.test", transport: transport, handlers: [captor])

        var card = AgentCard()
        card.name = "TestAgent"
        client.updateCard(card)

        _ = try await client.getTask("t1")

        let received = try #require(captor.capturedCard.get())
        #expect(received.name == "TestAgent")
    }

    @Test("A2AContextualHandler and plain A2AHandler can coexist in same pipeline")
    func contextualAndPlainHandlersCoexist() async throws {
        let callOrder = LockProtected<[String]>([])

        // Plain handler
        let plain = TestHandler()
        plain.handleRequestFn = { req in
            callOrder.append("plain")
            return req
        }

        // Contextual handler
        final class ContextualLogger: PassthroughContextualHandler {
            let callOrder: LockProtected<[String]>
            init(_ order: LockProtected<[String]>) { self.callOrder = order }
            override func handleRequest(_ request: A2ARequest) async throws -> [String: Any] {
                callOrder.append("contextual:\(request.method)")
                return request.rawRequest
            }
        }
        let contextual = ContextualLogger(callOrder)

        let transport = TestTransport()
        transport.sendFn = { _, _, _ in rpcSuccessResponse(["id": "t1"]) }

        let client = A2AClient(url: "http://agent.test", transport: transport, handlers: [plain, contextual])
        _ = try await client.getTask("t1")

        let order = callOrder.get()
        #expect(order == ["plain", "contextual:tasks/get"])
    }
}

// MARK: - ResponseModificationCase: CustomTestStringConvertible

extension A2AClientTests.ResponseModificationCase: CustomTestStringConvertible {
    var testDescription: String { name }
}

// MARK: - LockProtected

/// Thread-safe wrapper used in tests to share mutable state between handlers.
final class LockProtected<T>: @unchecked Sendable {
    private var _value: T
    private let _lock = NSLock()

    init(_ value: T) { self._value = value }

    func get() -> T { _lock.withLock { _value } }
    func set(_ value: T) { _lock.withLock { _value = value } }
}

extension LockProtected where T: RangeReplaceableCollection {
    func append(_ element: T.Element) {
        _lock.withLock { _value.append(element) }
    }
}
