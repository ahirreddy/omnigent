import XCTest

@testable import NativeLabCore

final class SubmissionLedgerTests: XCTestCase {
  private let scope = "http://127.0.0.1:6767|local"

  func testPendingSendRemainsBlockedWhenReconnectingToSameScope() throws {
    var ledger = SubmissionLedger()
    _ = try XCTUnwrap(ledger.begin(scope: scope, sessionID: "session", draft: "Hello"))
    XCTAssertEqual(ledger.pendingSessionIDs(in: scope), ["session"])
    XCTAssertTrue(ledger.pendingSessionIDs(in: "offline-demo").isEmpty)
    XCTAssertEqual(ledger.pendingSessionIDs(in: scope), ["session"])
    XCTAssertNil(ledger.begin(scope: scope, sessionID: "session", draft: "Hello again"))
  }

  func testLateAcceptedCompletionClearsSameDraftInReconnectedScope() throws {
    var ledger = SubmissionLedger()
    let operation = try XCTUnwrap(ledger.begin(scope: scope, sessionID: "session", draft: "Hello"))
    let result = try XCTUnwrap(
      ledger.complete(operation, outcome: .accepted, currentDraft: "Hello"))
    XCTAssertEqual(result.draft, "")
    XCTAssertFalse(result.isUncertain)
    XCTAssertTrue(ledger.pendingSessionIDs(in: scope).isEmpty)
  }

  func testLateAcceptedCompletionPreservesEditedDraft() throws {
    var ledger = SubmissionLedger()
    let operation = try XCTUnwrap(ledger.begin(scope: scope, sessionID: "session", draft: "Hello"))
    let result = try XCTUnwrap(
      ledger.complete(operation, outcome: .accepted, currentDraft: "A new thought"))
    XCTAssertEqual(result.draft, "A new thought")
  }

  func testUncertainCompletionRetainsDraftAndBlocksAcrossScopeSwitchUntilReview() throws {
    var ledger = SubmissionLedger()
    let operation = try XCTUnwrap(ledger.begin(scope: scope, sessionID: "session", draft: "Hello"))
    let result = try XCTUnwrap(
      ledger.complete(operation, outcome: .uncertain, currentDraft: "Hello"))
    XCTAssertEqual(result.draft, "Hello")
    XCTAssertTrue(result.isUncertain)
    XCTAssertEqual(ledger.uncertainSessionIDs(in: scope), ["session"])
    XCTAssertTrue(ledger.uncertainSessionIDs(in: "offline-demo").isEmpty)
    XCTAssertNil(ledger.begin(scope: scope, sessionID: "session", draft: "Changed draft"))
    ledger.acknowledgeUncertainty(scope: scope, sessionID: "session")
    XCTAssertTrue(ledger.uncertainSessionIDs(in: scope).isEmpty)
    XCTAssertNotNil(ledger.begin(scope: scope, sessionID: "session", draft: "Reviewed retry"))
  }

  func testRejectedCompletionRetainsDraftWithoutForcingAutomaticRetry() throws {
    var ledger = SubmissionLedger()
    let operation = try XCTUnwrap(ledger.begin(scope: scope, sessionID: "session", draft: "Hello"))
    let result = try XCTUnwrap(
      ledger.complete(operation, outcome: .rejected, currentDraft: "Hello"))
    XCTAssertEqual(result.draft, "Hello")
    XCTAssertFalse(result.isUncertain)
    XCTAssertTrue(ledger.pendingSessionIDs(in: scope).isEmpty)
    XCTAssertNotNil(ledger.begin(scope: scope, sessionID: "session", draft: "Manual retry"))
  }

  func testDuplicateOldCompletionCannotFinishNewerOperation() throws {
    var ledger = SubmissionLedger()
    let old = try XCTUnwrap(ledger.begin(scope: scope, sessionID: "session", draft: "First"))
    _ = ledger.complete(old, outcome: .accepted, currentDraft: "First")
    let newer = try XCTUnwrap(ledger.begin(scope: scope, sessionID: "session", draft: "Second"))
    XCTAssertNil(ledger.complete(old, outcome: .uncertain, currentDraft: "Second"))
    XCTAssertEqual(ledger.pendingSessionIDs(in: scope), ["session"])
    XCTAssertTrue(ledger.uncertainSessionIDs(in: scope).isEmpty)
    XCTAssertEqual(ledger.complete(newer, outcome: .accepted, currentDraft: "Second")?.draft, "")
  }

  func testSameSessionIDOnOtherServerOrAccountHasIndependentDeliveryState() throws {
    var ledger = SubmissionLedger()
    let old = try XCTUnwrap(ledger.begin(scope: scope, sessionID: "session", draft: "First"))
    let otherScope = "http://127.0.0.1:7777|other"
    let other = try XCTUnwrap(
      ledger.begin(scope: otherScope, sessionID: "session", draft: "Second"))
    _ = ledger.complete(old, outcome: .uncertain, currentDraft: "First")
    XCTAssertEqual(ledger.pendingSessionIDs(in: otherScope), ["session"])
    XCTAssertTrue(ledger.uncertainSessionIDs(in: otherScope).isEmpty)
    XCTAssertEqual(ledger.complete(other, outcome: .accepted, currentDraft: "Second")?.draft, "")
    XCTAssertEqual(ledger.uncertainSessionIDs(in: scope), ["session"])
  }
}
