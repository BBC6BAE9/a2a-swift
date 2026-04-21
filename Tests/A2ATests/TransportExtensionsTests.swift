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
@testable import A2A

// MARK: - TenantID Tests

@Suite("TenantID")
struct TenantIDTests {

    @Test("TaskLocal current is nil by default")
    func taskLocal_nilByDefault() async {
        #expect(TenantID.current == nil)
    }

    @Test("TaskLocal propagates value through withValue")
    func taskLocal_propagatesValue() async {
        await TenantID.$current.withValue("tenant-abc") {
            #expect(TenantID.current == "tenant-abc")
        }
    }

    @Test("TaskLocal value is nil after withValue block exits")
    func taskLocal_nilAfterBlock() async {
        await TenantID.$current.withValue("tenant-xyz") { }
        #expect(TenantID.current == nil)
    }

    @Test("TaskLocal propagates into child tasks")
    func taskLocal_propagatesIntoChildTask() async {
        await TenantID.$current.withValue("parent-tenant") {
            let task = _Concurrency.Task<String?, Never> { TenantID.current }
            let captured = await task.value
            #expect(captured == "parent-tenant")
        }
    }
}

// MARK: - TenantTransportDecorator Tests

@Suite("TenantTransportDecorator")
struct TenantTransportDecoratorTests {

    // MARK: Tenant injection via task-local

    @Test("injects tenant from TenantID.current into params")
    func injectsTenantFromTaskLocal() async throws {
        let inner = TestTransport()
        inner.sendFn = { req, _, _ in
            ["jsonrpc": "2.0", "id": "1", "result": ["tenant": req["params"] as Any]]
        }
        let decorator = TenantTransportDecorator(base: inner)

        var capturedRequest: [String: Any]?
        inner.sendFn = { req, path, params in
            capturedRequest = req
            return ["jsonrpc": "2.0", "id": "1", "result": [:]]
        }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "1",
            "method": "message/send",
            "params": ["message": "hello"],
        ]

        await TenantID.$current.withValue("acme-corp") {
            _ = try? await decorator.send(request, path: "", params: ServiceParams())
        }

        let sentParams = capturedRequest?["params"] as? [String: Any]
        #expect(sentParams?["tenant"] as? String == "acme-corp")
    }

    // MARK: Static tenant takes precedence over task-local

    @Test("static tenant wins over TenantID.current")
    func staticTenantWinsOverTaskLocal() async throws {
        let inner = TestTransport()
        var capturedRequest: [String: Any]?
        inner.sendFn = { req, _, _ in
            capturedRequest = req
            return ["jsonrpc": "2.0", "id": "1", "result": [:]]
        }

        let decorator = TenantTransportDecorator(base: inner, tenant: "static-tenant")

        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": "1",
            "method": "message/send",
            "params": [:],
        ]

        await TenantID.$current.withValue("task-local-tenant") {
            _ = try? await decorator.send(request, path: "", params: ServiceParams())
        }

        let sentParams = capturedRequest?["params"] as? [String: Any]
        #expect(sentParams?["tenant"] as? String == "static-tenant")
    }

    // MARK: Existing tenant in params is preserved

    @Test("existing tenant in params is preserved and not overwritten")
    func existingTenantPreserved() async throws {
        let inner = TestTransport()
        var capturedRequest: [String: Any]?
        inner.sendFn = { req, _, _ in
            capturedRequest = req
            return ["jsonrpc": "2.0", "id": "1", "result": [:]]
        }

        let decorator = TenantTransportDecorator(base: inner, tenant: "static-tenant")

        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": "1",
            "method": "message/send",
            "params": ["tenant": "original-tenant"],
        ]

        _ = try? await decorator.send(request, path: "", params: ServiceParams())

        let sentParams = capturedRequest?["params"] as? [String: Any]
        #expect(sentParams?["tenant"] as? String == "original-tenant")
    }

    // MARK: No tenant available — request passes through unmodified

    @Test("no tenant available: request passes through unmodified")
    func noTenantPassthrough() async throws {
        let inner = TestTransport()
        var capturedRequest: [String: Any]?
        inner.sendFn = { req, _, _ in
            capturedRequest = req
            return ["jsonrpc": "2.0", "id": "1", "result": [:]]
        }

        // No static tenant, no task-local.
        let decorator = TenantTransportDecorator(base: inner)

        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": "1",
            "method": "message/send",
            "params": ["message": "hello"],
        ]

        _ = try? await decorator.send(request, path: "", params: ServiceParams())

        let sentParams = capturedRequest?["params"] as? [String: Any]
        #expect(sentParams?["tenant"] == nil)
    }

    // MARK: get() forwards without modification

    @Test("get() forwards without tenant injection")
    func get_forwardsUnmodified() async throws {
        let inner = TestTransport()
        var capturedPath: String?
        inner.getFn = { path, _ in
            capturedPath = path
            return ["name": "TestAgent", "version": "1.0", "description": "d"]
        }

        let decorator = TenantTransportDecorator(base: inner, tenant: "t1")

        await TenantID.$current.withValue("t1") {
            _ = try? await decorator.get(path: "/card", params: ServiceParams())
        }

        #expect(capturedPath == "/card")
    }

    // MARK: sendStream injects tenant

    @Test("sendStream injects tenant into request")
    func sendStream_injectsTenant() async {
        let inner = TestTransport()
        var capturedRequest: [String: Any]?
        inner.sendStreamFn = { req, _ in
            capturedRequest = req
            return makeStream(events: [])
        }

        let decorator = TenantTransportDecorator(base: inner)

        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": "1",
            "method": "message/stream",
            "params": [:],
        ]

        await TenantID.$current.withValue("stream-tenant") {
            _ = try? await drainStream(
                decorator.sendStream(request, params: ServiceParams())
            )
        }

        let sentParams = capturedRequest?["params"] as? [String: Any]
        #expect(sentParams?["tenant"] as? String == "stream-tenant")
    }
}

// MARK: - A2ATransportFactory Tests

@Suite("A2ATransportFactory")
struct A2ATransportFactoryTests {

    // MARK: Fallback

    @Test("falls back to SseTransport when card has no supported interfaces")
    func fallback_emptyCard_sseTransport() {
        let factory = A2ATransportFactory()
        let card = AgentCard()
        let transport = factory.transport(for: card, baseURL: "http://agent.test")

        // The decorator wraps an SseTransport.
        guard let decorator = transport as? TenantTransportDecorator else {
            Issue.record("Expected TenantTransportDecorator, got \(type(of: transport))")
            return
        }
        #expect(decorator.base is SseTransport)
    }

    // MARK: JSON-RPC interface selected

    @Test("selects SseTransport for JSON_RPC binding")
    func selectsSSE_forJSONRPC() {
        let factory = A2ATransportFactory()
        var iface = AgentInterface()
        iface.url = "http://agent.test"
        iface.protocolBinding = A2AProtocolBinding.jsonRPC
        iface.protocolVersion = "1.0.0"

        var card = AgentCard()
        card.supportedInterfaces = [iface]

        let transport = factory.transport(for: card, baseURL: "http://fallback.test")
        guard let decorator = transport as? TenantTransportDecorator else {
            Issue.record("Expected TenantTransportDecorator"); return
        }
        #expect(decorator.base is SseTransport)
    }

    // MARK: REST interface selected

    @Test("selects RestTransport for HTTP_JSON binding")
    func selectsRest_forHTTPJSON() {
        let factory = A2ATransportFactory()
        var iface = AgentInterface()
        iface.url = "http://agent.test"
        iface.protocolBinding = A2AProtocolBinding.httpJSON
        iface.protocolVersion = "1.0.0"

        var card = AgentCard()
        card.supportedInterfaces = [iface]

        let transport = factory.transport(for: card, baseURL: "http://fallback.test")
        guard let decorator = transport as? TenantTransportDecorator else {
            Issue.record("Expected TenantTransportDecorator"); return
        }
        #expect(decorator.base is RestTransport)
    }

    // MARK: JSON-RPC preferred over REST at same version

    @Test("JSON_RPC preferred over HTTP_JSON at same version")
    func jsonRPCPreferredOverRESTAtSameVersion() {
        let factory = A2ATransportFactory()

        var rest = AgentInterface()
        rest.url = "http://rest.test"
        rest.protocolBinding = A2AProtocolBinding.httpJSON
        rest.protocolVersion = "1.0.0"

        var rpc = AgentInterface()
        rpc.url = "http://rpc.test"
        rpc.protocolBinding = A2AProtocolBinding.jsonRPC
        rpc.protocolVersion = "1.0.0"

        var card = AgentCard()
        card.supportedInterfaces = [rest, rpc]

        let transport = factory.transport(for: card, baseURL: "http://fallback.test")
        guard let decorator = transport as? TenantTransportDecorator else {
            Issue.record("Expected TenantTransportDecorator"); return
        }
        #expect(decorator.base is SseTransport, "JSON-RPC should win over REST at equal version")
    }

    // MARK: Higher version wins

    @Test("newer protocolVersion wins over older, regardless of binding preference")
    func newerVersionWins() {
        let factory = A2ATransportFactory()

        // Older JSON-RPC
        var oldRPC = AgentInterface()
        oldRPC.url = "http://old-rpc.test"
        oldRPC.protocolBinding = A2AProtocolBinding.jsonRPC
        oldRPC.protocolVersion = "1.0.0"

        // Newer REST
        var newREST = AgentInterface()
        newREST.url = "http://new-rest.test"
        newREST.protocolBinding = A2AProtocolBinding.httpJSON
        newREST.protocolVersion = "2.0.0"

        var card = AgentCard()
        card.supportedInterfaces = [oldRPC, newREST]

        let transport = factory.transport(for: card, baseURL: "http://fallback.test")
        guard let decorator = transport as? TenantTransportDecorator else {
            Issue.record("Expected TenantTransportDecorator"); return
        }
        #expect(decorator.base is RestTransport, "v2.0.0 REST should beat v1.0.0 JSON-RPC")
    }

    // MARK: Tenant is forwarded to decorator

    @Test("factory forwards tenant to TenantTransportDecorator")
    func tenantForwardedToDecorator() {
        let factory = A2ATransportFactory(tenant: "my-tenant")
        let card = AgentCard()
        let transport = factory.transport(for: card, baseURL: "http://agent.test")

        guard let decorator = transport as? TenantTransportDecorator else {
            Issue.record("Expected TenantTransportDecorator"); return
        }
        #expect(decorator.tenant == "my-tenant")
    }

    // MARK: Interface URL overrides baseURL

    @Test("interface url is used instead of fallback baseURL")
    func interfaceURL_overridesFallback() {
        let factory = A2ATransportFactory()

        var iface = AgentInterface()
        iface.url = "http://specific-host.test"
        iface.protocolBinding = A2AProtocolBinding.httpJSON
        iface.protocolVersion = "1.0.0"

        var card = AgentCard()
        card.supportedInterfaces = [iface]

        let transport = factory.transport(for: card, baseURL: "http://fallback.test")
        guard let decorator = transport as? TenantTransportDecorator,
              let rest = decorator.base as? RestTransport else {
            Issue.record("Expected TenantTransportDecorator wrapping RestTransport"); return
        }
        #expect(rest.url == "http://specific-host.test")
    }

    // MARK: Unknown binding is filtered out

    @Test("unknown protocol binding is ignored")
    func unknownBinding_filtered() {
        let factory = A2ATransportFactory()

        var unknown = AgentInterface()
        unknown.url = "http://grpc.test"
        unknown.protocolBinding = "GRPC"
        unknown.protocolVersion = "1.0.0"

        var card = AgentCard()
        card.supportedInterfaces = [unknown]

        let transport = factory.transport(for: card, baseURL: "http://fallback.test")
        guard let decorator = transport as? TenantTransportDecorator else {
            Issue.record("Expected TenantTransportDecorator"); return
        }
        // Falls back to SseTransport on fallback URL because gRPC is not supported.
        #expect(decorator.base is SseTransport)
    }
}

// MARK: - RestTransport route-mapping Tests

// Tests that share CapturingURLProtocol's static lastRequest must run serially.
@Suite("RestTransport routing", .serialized)
struct RestTransportRoutingTests {

    // MARK: Helpers

    /// Builds a minimal JSON-RPC request dict.
    private func rpcRequest(method: String, params: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": "1", "method": method, "params": params]
    }

    // MARK: send wraps REST response in result envelope

    @Test("send wraps response in JSON-RPC result envelope")
    func send_wrapsResponseInResultEnvelope() async throws {
        let session = makeMockSession(body: ["id": "t1", "status": ["state": "submitted"]])
        let transport = RestTransport(url: "http://agent.test", session: session)

        let response = try await transport.send(
            rpcRequest(method: "tasks/get", params: ["id": "t1"]),
            path: "",
            params: ServiceParams()
        )

        #expect(response["jsonrpc"] as? String == "2.0")
        #expect(response["result"] != nil)
    }

    // MARK: tasks/get

    @Test("tasks/get issues GET /tasks/{id}")
    func tasksGet_issuedAsGET() async throws {
        CapturingURLProtocol.lastRequest = nil
        let session = makeCapturingSession()
        let transport = RestTransport(url: "http://agent.test", session: session)

        _ = try? await transport.send(
            rpcRequest(method: "tasks/get", params: ["id": "task-123"]),
            path: "",
            params: ServiceParams()
        )

        #expect(CapturingURLProtocol.lastRequest?.httpMethod == "GET")
        #expect(CapturingURLProtocol.lastRequest?.url?.path == "/tasks/task-123")
    }

    // MARK: tasks/cancel

    @Test("tasks/cancel issues POST /tasks/{id}:cancel")
    func tasksCancel_issuedAsPOST() async throws {
        CapturingURLProtocol.lastRequest = nil
        let session = makeCapturingSession()
        let transport = RestTransport(url: "http://agent.test", session: session)

        _ = try? await transport.send(
            rpcRequest(method: "tasks/cancel", params: ["id": "task-456"]),
            path: "",
            params: ServiceParams()
        )

        #expect(CapturingURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(CapturingURLProtocol.lastRequest?.url?.path == "/tasks/task-456:cancel")
    }

    // MARK: tasks/list

    @Test("tasks/list issues GET /tasks with query params")
    func tasksList_issuedAsGETWithQueryParams() async throws {
        CapturingURLProtocol.lastRequest = nil
        let session = makeCapturingSession()
        let transport = RestTransport(url: "http://agent.test", session: session)

        _ = try? await transport.send(
            rpcRequest(method: "tasks/list", params: ["pageSize": 5, "contextId": "ctx-1"]),
            path: "",
            params: ServiceParams()
        )

        #expect(CapturingURLProtocol.lastRequest?.httpMethod == "GET")
        let url = CapturingURLProtocol.lastRequest?.url
        #expect(url?.path == "/tasks")
        let query = url?.query ?? ""
        #expect(query.contains("pageSize=5"))
        #expect(query.contains("contextId=ctx-1"))
    }

    // MARK: message/send

    @Test("message/send issues POST /messages:send")
    func messageSend_issuedAsPOST() async throws {
        CapturingURLProtocol.lastRequest = nil
        let session = makeCapturingSession()
        let transport = RestTransport(url: "http://agent.test", session: session)

        _ = try? await transport.send(
            rpcRequest(method: "message/send"),
            path: "",
            params: ServiceParams()
        )

        #expect(CapturingURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(CapturingURLProtocol.lastRequest?.url?.path == "/messages:send")
    }

    // MARK: getExtendedAgentCard

    @Test("getExtendedAgentCard issues GET /extendedAgentCard")
    func getExtendedAgentCard_issuedAsGET() async throws {
        CapturingURLProtocol.lastRequest = nil
        let session = makeCapturingSession()
        let transport = RestTransport(url: "http://agent.test", session: session)

        _ = try? await transport.send(
            rpcRequest(method: "getExtendedAgentCard"),
            path: "",
            params: ServiceParams()
        )

        #expect(CapturingURLProtocol.lastRequest?.httpMethod == "GET")
        #expect(CapturingURLProtocol.lastRequest?.url?.path == "/extendedAgentCard")
    }

    // MARK: pushNotificationConfig/set

    @Test("tasks/pushNotificationConfig/set issues POST /tasks/{taskId}/pushConfigs")
    func pushConfigSet_issuedAsPOST() async throws {
        CapturingURLProtocol.lastRequest = nil
        let session = makeCapturingSession()
        let transport = RestTransport(url: "http://agent.test", session: session)

        _ = try? await transport.send(
            rpcRequest(method: "tasks/pushNotificationConfig/set",
                       params: ["taskId": "t1", "url": "https://push.test"]),
            path: "",
            params: ServiceParams()
        )

        #expect(CapturingURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(CapturingURLProtocol.lastRequest?.url?.path == "/tasks/t1/pushConfigs")
    }

    // MARK: pushNotificationConfig/delete

    @Test("tasks/pushNotificationConfig/delete issues DELETE")
    func pushConfigDelete_issuedAsDELETE() async throws {
        CapturingURLProtocol.lastRequest = nil
        let session = makeCapturingSession()
        let transport = RestTransport(url: "http://agent.test", session: session)

        _ = try? await transport.send(
            rpcRequest(method: "tasks/pushNotificationConfig/delete",
                       params: ["taskId": "t1", "id": "cfg-99"]),
            path: "",
            params: ServiceParams()
        )

        #expect(CapturingURLProtocol.lastRequest?.httpMethod == "DELETE")
        #expect(CapturingURLProtocol.lastRequest?.url?.path == "/tasks/t1/pushConfigs/cfg-99")
    }

    // MARK: Unknown method throws

    @Test("unknown method throws unsupportedOperation")
    func unknownMethod_throws() async {
        CapturingURLProtocol.lastRequest = nil
        let session = makeCapturingSession()
        let transport = RestTransport(url: "http://agent.test", session: session)

        await #expect {
            _ = try await transport.send(
                rpcRequest(method: "bogus/method"),
                path: "",
                params: ServiceParams()
            )
        } throws: { error in
            guard case A2ATransportError.unsupportedOperation = error else { return false }
            return true
        }
    }

    // MARK: Missing method throws parsing error

    @Test("missing method key throws parsing error")
    func missingMethod_throws() async {
        let transport = RestTransport(url: "http://agent.test")

        await #expect {
            _ = try await transport.send(
                ["jsonrpc": "2.0", "id": "1"],
                path: "",
                params: ServiceParams()
            )
        } throws: { error in
            guard case A2ATransportError.parsing = error else { return false }
            return true
        }
    }
}

// MARK: - SemVer tests (white-box via factory observable behavior)

@Suite("SemVer ordering (via factory)")
struct SemVerOrderingTests {

    @Test("1.10.0 sorts above 1.9.0")
    func minorVersion_sortedCorrectly() {
        let factory = A2ATransportFactory()

        var old = AgentInterface()
        old.url = "http://old.test"
        old.protocolBinding = A2AProtocolBinding.httpJSON
        old.protocolVersion = "1.9.0"

        var new_ = AgentInterface()
        new_.url = "http://new.test"
        new_.protocolBinding = A2AProtocolBinding.httpJSON
        new_.protocolVersion = "1.10.0"

        var card = AgentCard()
        card.supportedInterfaces = [old, new_]

        let transport = factory.transport(for: card, baseURL: "http://fallback.test")
        guard let decorator = transport as? TenantTransportDecorator,
              let rest = decorator.base as? RestTransport else {
            Issue.record("Expected TenantTransportDecorator wrapping RestTransport"); return
        }
        #expect(rest.url == "http://new.test", "1.10.0 should win over 1.9.0")
    }
}

// MARK: - Test helpers

/// Returns a `URLSession` whose `data(for:)` always returns the given `body`
/// serialised as JSON with a 200 OK response.
private func makeMockSession(body: [String: Any]) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    MockURLProtocol.responseBody = try? JSONSerialization.data(withJSONObject: body)
    MockURLProtocol.statusCode = 200
    return URLSession(configuration: config)
}

/// Returns a `URLSession` backed by ``CapturingURLProtocol`` that records
/// the last request it receives.
private func makeCapturingSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CapturingURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - MockURLProtocol

/// A `URLProtocol` subclass that serves a static response body for any request.
private final class MockURLProtocol: URLProtocol {

    static var responseBody: Data? = "{}".data(using: .utf8)
    static var statusCode: Int = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: MockURLProtocol.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = MockURLProtocol.responseBody {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - CapturingURLProtocol

/// A `URLProtocol` subclass that records the last request it handles and
/// responds with an empty JSON object (`{}`) and HTTP 200.
///
/// Reset `lastRequest` to `nil` before each test to avoid stale state.
private final class CapturingURLProtocol: URLProtocol {

    /// The most recently handled request.  Set to `nil` before each test.
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        CapturingURLProtocol.lastRequest = request

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: "{}".data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
