import XCTest

@testable import NativeLabCore

final class ConversationStateTests: XCTestCase {
  func testNewerSnapshotReplacesMessagesAndDecisionsTogether() {
    let initial = DemoFixtures.snapshots[0]
    var state = ConversationState(snapshot: initial)
    var incoming = initial
    incoming.revision += 1
    incoming.decisions[0].response = .approve
    incoming.session.status = .idle
    incoming.messages.append(
      ConversationMessage(id: "next-message", role: .assistant, text: "Ready to continue.")
    )

    XCTAssertTrue(state.apply(incoming))
    XCTAssertEqual(state.snapshot, incoming)
    XCTAssertTrue(state.snapshot.pendingDecisions.isEmpty)
  }

  func testOlderAndEqualRevisionsCannotRestoreResolvedDecision() {
    let old = DemoFixtures.snapshots[0]
    var resolved = old
    resolved.revision += 1
    resolved.decisions[0].response = .approve
    resolved.session.status = .idle
    var state = ConversationState(snapshot: resolved)

    XCTAssertFalse(state.apply(old))
    var conflicting = old
    conflicting.revision = resolved.revision
    XCTAssertFalse(state.apply(conflicting))
    XCTAssertEqual(state.snapshot, resolved)
  }

  func testDifferentSessionIsRejectedEvenWithHigherRevision() {
    let initial = DemoFixtures.snapshots[0]
    var state = ConversationState(snapshot: initial)
    var anotherSession = DemoFixtures.snapshots[1]
    anotherSession.revision = 100

    XCTAssertFalse(state.apply(anotherSession))
    XCTAssertEqual(state.snapshot, initial)
  }
}
