# Phase 8: Startup Checklist — Before You Begin

## Pre-Implementation: Documentation Review

- [ ] Read `/Users/hong/Desktop/a2a/a2a-go/a2asrv/agentexec.go` (streaming template pattern)
- [ ] Read `/Users/hong/Desktop/a2a/a2a-go/internal/taskupdate/manager.go` (state machine logic)
- [ ] Read `/Users/hong/Desktop/a2a/a2a-go/a2asrv/push/api.go` (push notification system)
- [ ] Review PHASE_8_REFERENCE.md in this repo
- [ ] Review PHASE_8_SWIFT_PATTERNS.md in this repo

## Pre-Implementation: Environment Setup

- [ ] Swift version: 5.9+ (check with `swift --version`)
- [ ] Xcode: 15.0+ (optional, for IDE development)
- [ ] Clone a2a-go locally at `/Users/hong/Desktop/a2a/a2a-go` ✓ (already done)
- [ ] Clone a2a-swift locally at `/Users/hong/Desktop/a2a/a2a-swift` ✓ (already done)
- [ ] Run `swift build` in a2a-swift to ensure build works
- [ ] Verify test infrastructure: `swift test`

## Pre-Implementation: Directory Structure

Create the following directories (or let Xcode manage via Add Files):

```bash
mkdir -p Sources/A2A/Server
mkdir -p Tests/A2ATests/Server
mkdir -p Tests/A2ATests/Server/Fixtures
```

Verify structure:
```
Sources/A2A/Server/              (NEW)
├── AgentExecutor.swift
├── ExecutorContext.swift
├── TaskStore.swift
├── TaskUpdateManager.swift
├── ExecutionTermination.swift
├── PushNotifications.swift
├── HTTPPushSender.swift
├── RequestHandler.swift
├── A2AServer.swift
├── ExecutionManager.swift
└── Helpers/                      (NEW)
    └── EventEncoding.swift

Tests/A2ATests/Server/           (NEW)
├── AgentExecutorTests.swift
├── ExecutorContextTests.swift
├── TaskStoreTests.swift
├── TaskUpdateManagerTests.swift
├── PushNotificationTests.swift
├── HTTPPushSenderTests.swift
├── RequestHandlerTests.swift
├── ExecutionManagerTests.swift
├── IntegrationTests.swift
└── Fixtures/                     (NEW)
    ├── MockAgentExecutor.swift
    ├── MockTaskStore.swift
    └── TestData.swift
```

## Pre-Implementation: Existing Code Verification

Verify these existing types are in place (should be from Phases 1-7):

**Core Models:**
- [ ] `Task` struct with status, artifacts, metadata
- [ ] `TaskState` enum with 8 states + `isTerminal` property
- [ ] `TaskStatus` struct with state, message
- [ ] `Message` struct
- [ ] `Event` protocol
- [ ] `TaskStatusUpdateEvent` struct
- [ ] `TaskArtifactUpdateEvent` struct
- [ ] `ArtifactPart` struct
- [ ] `AgentCard` struct

**Supporting Types:**
- [ ] `ServiceParams` type (from Phase 4)
- [ ] `User` struct with identification
- [ ] `Codable` implementations for JSON serialization
- [ ] Error types: `A2AError`, `A2ATransportError`

**Verify Compilation:**
```bash
cd /Users/hong/Desktop/a2a/a2a-swift
swift build 2>&1 | grep -E "(error|warning)" | head -20
```

## Task Planning: Team Coordination (If Applicable)

### Sequential Execution (Single Person)
```
Week 1:
  - 8A1, 8A2, 8A3 (parallel) → 6-8 hours
  - 8B1, 8B2 (after 8A) → 8-10 hours
  
Week 2:
  - 8C1, 8C2 (parallel) → 4-6 hours
  - 8D1, 8D2 (after 8C) → 10-12 hours
  
Week 3:
  - 8E1 (after 8D) → 8-10 hours
  - 8F1-8F7 (after 8E) → 12-15 hours
```

### Parallel Execution (Team)
```
Pair A: 8A1 + 8A2 (start first)
Pair B: 8A3 (parallel with A)
Pair C: 8C1 + 8C2 (can start before A/B complete)

→ After A/B/C complete, proceed with 8B, 8D, 8E sequentially
```

## Implementation Setup: Templates

### File Header Template (for all new files)
```swift
// Copyright 2026 The A2A Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import A2A

// MARK: - [Component Name]

/// [Component description and purpose]
```

### Test File Template
```swift
import XCTest
@testable import A2A

final class [ComponentName]Tests: XCTestCase {
    
    // MARK: - Setup & Teardown
    
    override func setUp() async throws {
        try await super.setUp()
        // Common setup
    }
    
    override func tearDown() async throws {
        // Common cleanup
        try await super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func testBasicFunctionality() async throws {
        // Arrange
        
        // Act
        
        // Assert
    }
    
    // MARK: - Error Handling Tests
    
    func testErrorCondition() async throws {
        // Test error paths
    }
    
    // MARK: - Edge Cases
    
    func testEdgeCase() async throws {
        // Test boundary conditions
    }
}
```

## Implementation Starting Points: Quick Reference

### Task 8A1: AgentExecutor Protocol
**Go Reference:** `a2a-go/a2asrv/agentexec.go:95-120`
**Key Pattern:** Streaming with `AsyncThrowingSequence`
**Estimated Time:** 1-2 hours

**Pseudocode:**
```swift
protocol AgentExecutor {
    func execute(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error>
    func cancel(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error>
}

protocol AgentExecutionCleaner {
    func cleanup(context: ExecutorContext, result: SendMessageResult, error: Error?) async
}
```

### Task 8A2: ExecutorContext
**Go Reference:** `a2a-go/a2asrv/exectx.go:40-103`
**Key Pattern:** Task-local storage + struct with optional fields
**Estimated Time:** 1-1.5 hours

**Pseudocode:**
```swift
class ExecutorContext {
    let message: Message?
    let taskID: TaskID
    let storedTask: StoredTask?
    let contextID: ContextID
    // ... 5 more fields
    
    @TaskLocal static var current: ExecutorContext?
}

extension ExecutorContext: TaskInfoProvider { ... }
```

### Task 8A3: TaskStore Protocol & OCC
**Go Reference:** `a2a-go/a2asrv/taskstore/api.go`
**Key Pattern:** Version-based OCC, protocol definition
**Estimated Time:** 2-3 hours

**Pseudocode:**
```swift
typealias TaskVersion = Int64

struct StoredTask {
    let task: Task
    let version: TaskVersion
}

protocol TaskStore {
    func create(task: Task) async throws -> TaskVersion
    func update(request: UpdateRequest) async throws -> TaskVersion
    func get(taskID: TaskID) async throws -> StoredTask
    func list(request: ListTasksRequest) async throws -> ListTasksResponse
}
```

### Task 8B1: TaskUpdateManager
**Go Reference:** `a2a-go/internal/taskupdate/manager.go`
**Key Pattern:** Event dispatch, state validation, OCC retry loop
**Estimated Time:** 4-5 hours

**Pseudocode:**
```swift
class TaskUpdateManager {
    func process(_ event: Event) async throws -> StoredTask
    func setTaskFailed(_ cause: Error) async throws -> StoredTask
    
    private func updateArtifact(_ event: TaskArtifactUpdateEvent) async throws -> StoredTask
    private func updateStatus(_ event: TaskStatusUpdateEvent) async throws -> StoredTask
    private func validate(_ event: TaskInfoProvider) throws
}
```

## Implementation Workflow: Per-Task Checklist

For each task, follow this process:

### Step 1: Understand
- [ ] Read Go source code
- [ ] Review PHASE_8_REFERENCE.md section
- [ ] Review PHASE_8_SWIFT_PATTERNS.md examples

### Step 2: Plan
- [ ] Sketch types/functions on paper
- [ ] Identify dependencies
- [ ] Plan error handling
- [ ] Consider edge cases

### Step 3: Implement
- [ ] Create `.swift` file with header
- [ ] Define types/protocols
- [ ] Implement methods
- [ ] Add inline documentation
- [ ] Handle errors

### Step 4: Test
- [ ] Create test file
- [ ] Write happy path tests
- [ ] Write error case tests
- [ ] Write edge case tests
- [ ] Run: `swift test [ComponentName]Tests`

### Step 5: Review
- [ ] Check code against reference
- [ ] Verify all methods present
- [ ] Check error handling
- [ ] Verify documentation
- [ ] Run full test suite: `swift test`

### Step 6: Commit
```bash
git add Sources/A2A/Server/[Component].swift Tests/A2ATests/Server/[Component]Tests.swift
git commit -m "Add Phase 8[Letter][Number]: [Component Description]"
```

## Development Workflow Recommendations

### Use Provided Templates
1. Copy `PHASE_8_SWIFT_PATTERNS.md` to your IDE
2. Reference code examples directly
3. Adapt to your implementation

### Incremental Development
1. Start with protocols (no implementation)
2. Add in-memory implementations first
3. Add tests alongside code
4. Refactor after basic functionality works

### Debugging Tips
```swift
// Use AsyncStream debugging
private func debugYield(_ event: Event) {
    #if DEBUG
    print("🚀 Event: \(type(of: event))")
    #endif
}

// Use breakpoints in async contexts
func execute(context: ExecutorContext) -> AsyncThrowingSequence<Event, Error> {
    AsyncThrowingStream { continuation in
        debugYield(Task(...))  // breakpoint here
        continuation.yield(task)
    }
}
```

## Running Tests During Development

```bash
# Run all tests
swift test

# Run specific test class
swift test --filter TaskStoreTests

# Run specific test method
swift test --filter TaskStoreTests.testCreateTask

# Run with verbose output
swift test --verbose

# Run with coverage report
swift test --code-coverage

# Check coverage percentage
xcrun llvm-cov report \
  .build/debug/A2APackageTests.xctest/Contents/MacOS/A2APackageTests \
  -instr-profile .build/debug/codecov/default.profdata \
  -use-color
```

## Continuous Integration: Pre-commit Checks

Before committing, run:
```bash
# 1. Format check (if using SwiftFormat)
swiftformat --lint Sources/A2A/Server/ Tests/A2ATests/Server/

# 2. Build check
swift build

# 3. Test check
swift test

# 4. Linting (if using SwiftLint)
swiftlint Sources/A2A/Server/ Tests/A2ATests/Server/
```

## When Stuck: Troubleshooting Guide

### Compilation Errors

**"Cannot find type 'X' in scope"**
- Check that X is defined in Core module
- Verify import statement
- Check Task/Module access level

**"Async method cannot be @discardableResult"**
- Don't apply @discardableResult to async functions
- Return Void explicitly if needed

**"Type does not conform to protocol 'X'"**
- Verify all required methods implemented
- Check method signatures match exactly
- Check return types are correct

### Test Failures

**"Async operation timed out"**
- Increase timeout in test
- Check for deadlocks in code
- Verify continuation is called

**"Context already has a value"**
- Don't nest $current.withValue calls
- Use single TaskLocal per context

### Runtime Issues

**Memory pressure with streaming**
- Ensure continuations finish() or finish(throwing:)
- Don't hold onto continuation beyond scope
- Test with large payload volumes

## Success Indicators

For each completed task:
- [ ] Code compiles without warnings
- [ ] All tests pass (`swift test` green)
- [ ] Documentation is clear and complete
- [ ] Error cases are handled
- [ ] Edge cases work correctly

## Moving Forward

Once you've completed this checklist:
1. Begin with Task 8A1 (AgentExecutor Protocol)
2. Refer to PHASE_8_REFERENCE.md constantly
3. Use PHASE_8_SWIFT_PATTERNS.md for code examples
4. Follow the Implementation Workflow above
5. Track progress in task management system

---

**Good luck! Happy coding! 🚀**

For questions, refer to:
- PHASE_8_REFERENCE.md - Detailed specifications
- PHASE_8_SWIFT_PATTERNS.md - Implementation patterns
- Go source: `/Users/hong/Desktop/a2a/a2a-go/a2asrv/`

