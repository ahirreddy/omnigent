import XCTest

@testable import NativeLabCore

final class DemoSessionClientTests: XCTestCase {
  func testInitialUpdatesIncludeEverySessionAndNewSessionsArePublished() async throws {
    let client = DemoSessionClient()
    let stream = await client.updates()
    var iterator = stream.makeAsyncIterator()
    var initialIDs: Set<String> = []
    for _ in DemoFixtures.snapshots {
      let snapshot = await iterator.next()
      initialIDs.insert(try XCTUnwrap(snapshot).id)
    }
    XCTAssertEqual(initialIDs, Set(DemoFixtures.snapshots.map(\.id)))

    let created = try await client.createSession(title: "  A focused session  ")
    let announced = await iterator.next()
    XCTAssertEqual(announced, created)
    XCTAssertEqual(created.session.title, "A focused session")
    XCTAssertEqual(created.session.status, .idle)
    XCTAssertFalse(created.session.isReadOnly)
    XCTAssertTrue(created.messages.isEmpty)
    let sessions = try await client.sessions()
    XCTAssertEqual(sessions.first?.id, created.id)

    let second = try await client.createSession(title: "\n ")
    XCTAssertNotEqual(second.id, created.id)
    XCTAssertEqual(second.session.title, "New conversation")
  }

  func testSendConstraintsLeaveExistingStateUnchanged() async throws {
    let client = DemoSessionClient()
    let readOnlyBefore = try await client.conversation(id: "demo-notes")
    await assertClientError(.readOnly) {
      try await client.send("Change these notes", to: "demo-notes")
    }
    let readOnlyAfter = try await client.conversation(id: "demo-notes")
    XCTAssertEqual(readOnlyBefore, readOnlyAfter)

    let pendingBefore = try await client.conversation(id: "demo-design")
    await assertClientError(.needsDecision) {
      try await client.send("Continue", to: "demo-design")
    }
    let pendingAfter = try await client.conversation(id: "demo-design")
    XCTAssertEqual(pendingBefore, pendingAfter)

    let empty = try await client.createSession(title: "Empty input")
    await assertClientError(.emptyMessage) {
      try await client.send(" \t\n ", to: empty.id)
    }
    let stillEmpty = try await client.conversation(id: empty.id)
    XCTAssertEqual(stillEmpty, empty)
  }

  func testBinaryDecisionsResolveOnceAndPublish() async throws {
    for response in [DecisionResponse.approve, .decline] {
      let client = DemoSessionClient()
      let stream = await client.updates()
      var iterator = stream.makeAsyncIterator()
      for _ in DemoFixtures.snapshots { _ = await iterator.next() }

      try await client.resolve(
        decisionID: "decision-design", sessionID: "demo-design", response: response
      )
      let nextSnapshot = await iterator.next()
      let emitted = try XCTUnwrap(nextSnapshot)
      XCTAssertEqual(emitted.id, "demo-design")
      XCTAssertEqual(emitted.decisions.first?.response, response)
      XCTAssertTrue(emitted.pendingDecisions.isEmpty)
      XCTAssertEqual(emitted.session.status, .idle)

      await assertClientError(.decisionAlreadyResolved) {
        try await client.resolve(
          decisionID: "decision-design", sessionID: "demo-design", response: .approve
        )
      }
      let afterDuplicate = try await client.conversation(id: "demo-design")
      XCTAssertEqual(afterDuplicate, emitted)
    }
  }

  func testQuestionRejectsUnknownAnswerAndBinaryResponsesThenAcceptsAnOption() async throws {
    let client = DemoSessionClient()
    let before = try await client.conversation(id: "demo-question")
    for response in [DecisionResponse.answer("Everything"), .approve, .decline] {
      await assertClientError(.invalidDecision) {
        try await client.resolve(
          decisionID: "decision-question", sessionID: "demo-question", response: response
        )
      }
    }
    let afterInvalid = try await client.conversation(id: "demo-question")
    XCTAssertEqual(afterInvalid, before)

    try await client.resolve(
      decisionID: "decision-question", sessionID: "demo-question",
      response: .answer("Approvals first")
    )
    let answered = try await client.conversation(id: "demo-question")
    XCTAssertEqual(answered.decisions.first?.response, .answer("Approvals first"))
    XCTAssertEqual(answered.session.status, .idle)
    XCTAssertTrue(answered.pendingDecisions.isEmpty)
    await assertClientError(.decisionAlreadyResolved) {
      try await client.resolve(
        decisionID: "decision-question", sessionID: "demo-question",
        response: .answer("Sessions and chat")
      )
    }
  }

  func testDecisionCannotBeAnsweredThroughAnotherSessionOrWithWrongKind() async throws {
    let client = DemoSessionClient()
    let originalDesign = try await client.conversation(id: "demo-design")
    let originalQuestion = try await client.conversation(id: "demo-question")
    await assertClientError(.decisionNotFound) {
      try await client.resolve(
        decisionID: "decision-design", sessionID: "demo-question", response: .approve
      )
    }
    await assertClientError(.invalidDecision) {
      try await client.resolve(
        decisionID: "decision-design", sessionID: "demo-design", response: .answer("Yes")
      )
    }
    await assertClientError(.readOnly) {
      try await client.resolve(
        decisionID: "decision-design", sessionID: "demo-notes", response: .approve
      )
    }
    let design = try await client.conversation(id: "demo-design")
    let question = try await client.conversation(id: "demo-question")
    XCTAssertEqual(design, originalDesign)
    XCTAssertEqual(question, originalQuestion)
  }

  func testReplyStreamsIncreasingRevisionsAndFinishesInItsOwnSession() async throws {
    let client = DemoSessionClient(responseDelayNanoseconds: 0)
    let created = try await client.createSession(title: "Streaming")
    let untouched = try await client.conversation(id: "demo-notes")
    let stream = await client.updates()
    let recorder = SnapshotRecorder()
    let finished = expectation(description: "The sample reply finishes")
    let listener = Task {
      for await snapshot in stream where snapshot.id == created.id {
        await recorder.append(snapshot)
        if snapshot.session.status == .idle, snapshot.messages.last?.role == .assistant {
          finished.fulfill()
          return
        }
      }
    }

    try await client.send("  Hello from the phone  ", to: created.id)
    await fulfillment(of: [finished], timeout: 3)
    listener.cancel()
    await listener.value
    let history = await recorder.snapshots
    XCTAssertGreaterThan(history.count, 3)
    XCTAssertTrue(history.contains { $0.messages.last?.isStreaming == true })
    for pair in zip(history, history.dropFirst()) {
      XCTAssertLessThan(pair.0.revision, pair.1.revision)
    }
    let final = try await client.conversation(id: created.id)
    XCTAssertEqual(final.messages.count, 2)
    XCTAssertEqual(final.messages.first?.text, "Hello from the phone")
    XCTAssertEqual(
      final.messages.last?.text,
      """
      Got it. This is a sample reply from the offline demo. Your message stayed in this \
      conversation. You can try another message or create a new session.
      """
    )
    XCTAssertFalse(try XCTUnwrap(final.messages.last).isStreaming)
    XCTAssertEqual(final.session.status, .idle)
    let stillUntouched = try await client.conversation(id: "demo-notes")
    XCTAssertEqual(stillUntouched, untouched)
  }

  func testInterruptCancelsReplyAndDoesNotChangeAnotherRunningSession() async throws {
    // The long delay is a cancellable gate; the test never waits for it to expire.
    let client = DemoSessionClient(responseDelayNanoseconds: 60_000_000_000)
    let first = try await client.createSession(title: "First")
    let second = try await client.createSession(title: "Second")
    try await client.send("First prompt", to: first.id)
    try await client.send("Second prompt", to: second.id)
    let secondBefore = try await client.conversation(id: second.id)

    await assertClientError(.busy) {
      try await client.send("Duplicate while running", to: first.id)
    }
    try await client.interrupt(sessionID: first.id)
    let stopped = try await client.conversation(id: first.id)
    XCTAssertEqual(stopped.session.status, .idle)
    XCTAssertEqual(stopped.messages.last?.text, "Reply stopped.")
    XCTAssertFalse(try XCTUnwrap(stopped.messages.last).isStreaming)
    let secondAfter = try await client.conversation(id: second.id)
    XCTAssertEqual(secondAfter, secondBefore)
    XCTAssertEqual(secondAfter.session.status, .running)

    try await client.send("Try again", to: first.id)
    let restarted = try await client.conversation(id: first.id)
    XCTAssertEqual(restarted.messages.count, 4)
    XCTAssertEqual(restarted.messages[1], stopped.messages[1])
    XCTAssertNotEqual(restarted.messages.last?.id, stopped.messages.last?.id)
    try await client.interrupt(sessionID: first.id)
    try await client.interrupt(sessionID: second.id)
    let final = try await client.conversation(id: first.id)
    try await client.interrupt(sessionID: first.id)
    let afterRepeatedStop = try await client.conversation(id: first.id)
    XCTAssertEqual(final, afterRepeatedStop)
    XCTAssertTrue(final.messages.allSatisfy { !$0.isStreaming })
  }

  func testCancellingSubscriberRemovesItsContinuation() async {
    let client = DemoSessionClient()
    let stream = await client.updates()
    let started = expectation(description: "Subscriber receives its initial snapshot")
    let listener = Task {
      var receivedInitial = false
      for await _ in stream {
        if !receivedInitial {
          receivedInitial = true
          started.fulfill()
        }
      }
    }
    await fulfillment(of: [started], timeout: 3)
    let connectedCount = await client.activeSubscriptionCount
    XCTAssertEqual(connectedCount, 1)
    listener.cancel()
    await listener.value

    // onTermination schedules actor cleanup; yield to that task without sleeping.
    for _ in 0..<1_000 {
      if await client.activeSubscriptionCount == 0 { break }
      await Task.yield()
    }
    let remainingCount = await client.activeSubscriptionCount
    XCTAssertEqual(remainingCount, 0)
  }

  func testUnknownSessionOperationsFailWithoutCreatingState() async {
    let client = DemoSessionClient()
    await assertClientError(.sessionNotFound) {
      _ = try await client.conversation(id: "missing")
    }
    await assertClientError(.sessionNotFound) {
      try await client.send("Hello", to: "missing")
    }
    await assertClientError(.sessionNotFound) {
      try await client.interrupt(sessionID: "missing")
    }
    await assertClientError(.sessionNotFound) {
      try await client.resolve(
        decisionID: "decision-design", sessionID: "missing", response: .approve
      )
    }
  }

  private func assertClientError(
    _ expected: SessionClientError, file: StaticString = #filePath, line: UInt = #line,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? SessionClientError, expected, file: file, line: line)
    }
  }
}

private actor SnapshotRecorder {
  private(set) var snapshots: [ConversationSnapshot] = []

  func append(_ snapshot: ConversationSnapshot) {
    snapshots.append(snapshot)
  }
}
