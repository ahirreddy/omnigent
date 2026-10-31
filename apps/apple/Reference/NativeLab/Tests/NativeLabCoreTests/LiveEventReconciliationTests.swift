import Foundation
import XCTest

@testable import NativeLabCore

final class LiveEventReconciliationTests: XCTestCase {
  func testStoppedPartialTextAndFileKeepTheirChronologyAcrossHydration() throws {
    let user = ConversationMessage(id: "user", role: .user, text: "Question")
    var reducer = makeReducer([user])
    try send(&reducer, #"{"type":"response.created","response":{"id":"r1"}}"#)
    try send(&reducer, #"{"type":"response.output_text.delta","delta":"Partial answer"}"#)
    try send(
      &reducer, #"{"type":"response.output_file.done","file_id":"file-1","filename":"report.txt"}"#)
    try send(&reducer, #"{"type":"response.completed","response":{"id":"r1"}}"#)
    let file = try XCTUnwrap(reducer.snapshot.messages.first { $0.activity?.kind == .file })
    let newer = ConversationMessage(id: "newer", role: .user, text: "Next question")
    reducer.reconcile(with: makeReducer([user, newer]).snapshot)
    XCTAssertEqual(
      reducer.snapshot.messages.map(\.id), ["user", "live:response:r1:0", file.id, "newer"])
    XCTAssertFalse(reducer.snapshot.messages.contains(where: \.isStreaming))
    XCTAssertEqual(reducer.snapshot.messages[2].attachments?.first?.reference, "file-1")
    let final = ConversationMessage(
      id: "final", role: .assistant, text: "Partial answer", responseID: "r1")
    reducer.reconcile(with: makeReducer([user, final, newer]).snapshot)
    XCTAssertEqual(reducer.snapshot.messages.map(\.id), ["user", "final", file.id, "newer"])
  }

  func testNativeFinalSealsPreviewAndRejectsLateOrFractionalIndices() throws {
    var reducer = makeReducer()
    try send(
      &reducer,
      #"{"type":"response.output_text.delta","message_id":"m1","index":0,"delta":"Hello"}"#)
    try send(
      &reducer,
      #"{"type":"response.output_text.delta","message_id":"m1","index":0.5,"delta":"INVALID"}"#)
    try send(
      &reducer,
      #"{"type":"response.output_text.delta","message_id":"m1","index":1,"delta":" world","final":true}"#
    )
    try send(
      &reducer, #"{"type":"response.output_text.delta","message_id":"m1","index":2,"delta":"LATE"}"#
    )
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["Hello world"])
    XCTAssertFalse(reducer.snapshot.messages[0].isStreaming)
    reducer.reconcile(with: makeReducer().snapshot)
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["Hello world"])
  }

  func testNativeMessagesWithoutOptionalIndicesKeepEveryDelta() throws {
    var reducer = makeReducer()
    try send(&reducer, #"{"type":"response.output_text.delta","message_id":"m1","delta":"Hello"}"#)
    try send(&reducer, #"{"type":"response.output_text.delta","message_id":"m1","delta":" world"}"#)
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["Hello world"])
  }

  func testOldResponseStartStatusAndDeltasCannotInterruptNewResponse() throws {
    var reducer = makeReducer()
    try send(&reducer, #"{"type":"response.created","response":{"id":"old"}}"#)
    try send(&reducer, #"{"type":"response.output_text.delta","delta":"Old partial"}"#)
    try send(
      &reducer, #"{"type":"response.created","response":{"id":"new","previous_response_id":"old"}}"#
    )
    try send(
      &reducer, #"{"type":"response.output_text.delta","response_id":"new","delta":"New partial"}"#)
    let current = reducer.snapshot
    for stale in [
      #"{"type":"response.created","response":{"id":"old"}}"#,
      #"{"type":"session.status","status":"idle","response_id":"old"}"#,
      #"{"type":"session.status","status":"running","response_id":"old"}"#,
      #"{"type":"response.output_text.delta","response_id":"old","delta":"Stale"}"#,
      #"{"type":"response.reasoning_summary_text.delta","response_id":"old","delta":"Stale"}"#,
    ] {
      try send(&reducer, stale)
      XCTAssertEqual(reducer.snapshot, current, stale)
    }
    XCTAssertFalse(reducer.snapshot.messages[0].isStreaming)
    XCTAssertTrue(reducer.snapshot.messages[1].isStreaming)
    try send(
      &reducer,
      #"{"type":"response.output_item.done","item":{"id":"old-final","type":"message","role":"assistant","response_id":"old","content":"Old partial complete"}}"#
    )
    XCTAssertEqual(reducer.snapshot.messages.map(\.id), ["old-final", "live:response:new:0"])
    XCTAssertTrue(reducer.snapshot.messages.last?.isStreaming == true)
  }

  func testRepeatedToolCallIDsRemainResponseScopedAndOldCommitDoesNotConsumeNewPreview() throws {
    var reducer = makeReducer()
    let old =
      #"{"type":"response.output_item.done","item":{"id":"old-result","type":"function_call_output","call_id":"call","response_id":"r1","output":"Old output"}}"#
    try send(&reducer, #"{"type":"response.created","response":{"id":"r1"}}"#)
    try send(
      &reducer,
      #"{"type":"response.function_call_output.delta","call_id":"call","index":0,"delta":"Old"}"#)
    try send(&reducer, old)
    try send(&reducer, #"{"type":"response.created","response":{"id":"r2"}}"#)
    try send(
      &reducer,
      #"{"type":"response.function_call_output.delta","call_id":"call","index":0,"delta":"New output"}"#
    )
    try send(&reducer, old)
    XCTAssertEqual(reducer.snapshot.messages.count, 2)
    XCTAssertEqual(reducer.snapshot.messages.last?.responseID, "r2")
    XCTAssertTrue(
      reducer.snapshot.messages.last?.activity?.details.first?.text.contains("New output") == true)
    try send(
      &reducer,
      #"{"type":"response.output_item.done","item":{"id":"new-result","type":"function_call_output","call_id":"call","response_id":"r2","output":"New output complete"}}"#
    )
    try send(
      &reducer,
      #"{"type":"response.function_call_output.delta","call_id":"call","index":1,"delta":"Late replay"}"#
    )
    XCTAssertEqual(reducer.snapshot.messages.map(\.id), ["old-result", "new-result"])
  }

  func testReasoningCommitReplayAndHydrationRetireOnlyCorrespondingSummary() throws {
    var reducer = makeReducer()
    try send(&reducer, #"{"type":"response.created","response":{"id":"r1"}}"#)
    try send(
      &reducer,
      #"{"type":"response.reasoning_summary_text.delta","item_id":"summary1","index":0,"delta":"First summary"}"#
    )
    let first =
      #"{"type":"response.output_item.done","item":{"id":"summary1","type":"reasoning","response_id":"r1","summary":[{"type":"summary_text","text":"First summary"}]}}"#
    try send(&reducer, first)
    try send(
      &reducer,
      #"{"type":"response.reasoning_summary_text.delta","item_id":"summary2","index":0,"delta":"Second summary"}"#
    )
    try send(&reducer, first)
    try send(
      &reducer,
      #"{"type":"response.reasoning_summary_text.delta","item_id":"summary1","index":1,"delta":"Late first summary"}"#
    )
    XCTAssertEqual(reducer.snapshot.messages.count, 2)
    XCTAssertTrue(reducer.snapshot.messages.last?.isStreaming == true)
    let final = ConversationMessage(
      id: "summary2", role: .tool, text: "Summary",
      activity:
        .init(
          kind: .reasoning, title: "Reasoning summary", summary: "Second summary",
          details: [.init(id: "summary", title: "Summary", text: "Second summary")]),
      responseID: "r1")
    reducer.reconcile(with: makeReducer([reducer.snapshot.messages[0], final]).snapshot)
    try send(
      &reducer,
      #"{"type":"response.reasoning_summary_text.delta","item_id":"summary2","index":1,"delta":"Late second summary"}"#
    )
    XCTAssertEqual(reducer.snapshot.messages.map(\.id), ["summary1", "summary2"])
  }

  func testErrorLiveStatusStoredAndReplayBecomeOneReadableRow() throws {
    var reducer = makeReducer()
    try send(&reducer, #"{"type":"response.created","response":{"id":"r1"}}"#)
    let error = #"{"type":"response.error","error":{"code":"failed","message":"Visible failure"}}"#
    try send(&reducer, error)
    try send(
      &reducer,
      #"{"type":"session.status","status":"failed","response_id":"r1","error":{"code":"failed","message":"Visible failure"}}"#
    )
    try send(
      &reducer,
      #"{"type":"response.output_item.done","item":{"id":"error1","type":"error","response_id":"r1","code":"failed","message":"Visible failure"}}"#
    )
    try send(&reducer, error)
    XCTAssertEqual(reducer.snapshot.messages.map(\.id), ["error1"])
    XCTAssertEqual(reducer.snapshot.session.failureMessage, "Visible failure")
  }

  func testSessionIdleSealsAllActivityAndLateDeltasCannotRestartSpinner() throws {
    var reducer = makeReducer()
    try send(&reducer, #"{"type":"response.created","response":{"id":"r1"}}"#)
    try send(
      &reducer, #"{"type":"response.reasoning_summary_text.delta","delta":"Visible summary"}"#)
    try send(
      &reducer,
      #"{"type":"response.function_call_output.delta","call_id":"call","delta":"Partial output"}"#)
    try send(&reducer, #"{"type":"response.compaction.in_progress"}"#)
    try send(&reducer, #"{"type":"session.status","status":"idle"}"#)
    let rows = reducer.snapshot.messages
    for event in [
      #"{"type":"response.reasoning_summary_text.delta","delta":"Late"}"#,
      #"{"type":"response.function_call_output.delta","call_id":"call","delta":"Late"}"#,
      #"{"type":"response.output_text.delta","delta":"Late"}"#,
    ] { try send(&reducer, event) }
    XCTAssertEqual(reducer.snapshot.messages, rows)
    XCTAssertFalse(rows.contains(where: \.isStreaming))
    XCTAssertFalse(rows.contains { $0.activity?.status == "in_progress" })
    XCTAssertEqual(reducer.snapshot.session.status, .idle)
  }

  func testResolvedElicitationReplayCannotReappearAndUnknownResolutionDoesNotStopResponse() throws {
    var reducer = makeReducer()
    try send(&reducer, #"{"type":"response.created","response":{"id":"r1"}}"#)
    try send(&reducer, #"{"type":"response.elicitation_resolved","elicitation_id":"unrelated"}"#)
    XCTAssertEqual(reducer.snapshot.session.status, .running)
    let request =
      #"{"type":"response.elicitation_request","elicitation_id":"ask1","params":{"message":"Approve?"}}"#
    try send(&reducer, request)
    let stale = reducer.snapshot
    try send(&reducer, #"{"type":"response.elicitation_resolved","elicitation_id":"ask1"}"#)
    try send(&reducer, request)
    reducer.reconcile(with: stale)
    XCTAssertTrue(reducer.snapshot.pendingDecisions.isEmpty)
    XCTAssertFalse(reducer.snapshot.decisions.contains { $0.id == "ask1" })
    XCTAssertEqual(reducer.snapshot.session.status, .running)
  }

  func testInvalidSessionStatusDoesNotPoisonMetadata() throws {
    var reducer = makeReducer()
    try send(&reducer, #"{"type":"session.status","status":"running"}"#)
    let before = reducer.snapshot
    try send(&reducer, #"{"type":"session.status","status":"nonsense","background_task_count":10}"#)
    XCTAssertEqual(reducer.snapshot, before)
  }

  func testIncompleteReasonIsVisibleAfterResponseStops() throws {
    var reducer = makeReducer()
    try send(&reducer, #"{"type":"response.created","response":{"id":"r1"}}"#)
    try send(
      &reducer,
      #"{"type":"response.incomplete","response":{"id":"r1","incomplete_details":{"reason":"max_output_tokens"}}}"#
    )
    XCTAssertEqual(reducer.snapshot.session.status, .idle)
    XCTAssertEqual(reducer.snapshot.session.failureMessage, "max_output_tokens")
    XCTAssertEqual(reducer.snapshot.messages.first?.activity?.kind, .error)
  }

  func testStreamingStructuredToolOutputDoesNotLeakPartialSecrets() throws {
    var reducer = makeReducer()
    try send(
      &reducer,
      #"{"type":"response.function_call_output.delta","call_id":"call","delta":"{\"api_key\":\"PRIVATE"}"#
    )
    XCTAssertFalse(
      reducer.snapshot.messages.first?.activity?.details.first?.text.contains("PRIVATE") == true)
    try send(
      &reducer,
      #"{"type":"response.function_call_output.delta","call_id":"call","delta":"\",\"result\":\"Visible\"}"}"#
    )
    let detail = try XCTUnwrap(reducer.snapshot.messages.first?.activity?.details.first?.text)
    XCTAssertTrue(detail.contains("Visible"))
    XCTAssertFalse(detail.contains("PRIVATE"))
  }

  private func makeReducer(_ messages: [ConversationMessage] = []) -> LiveConversationReducer {
    LiveConversationReducer(
      snapshot: .init(
        revision: 1,
        session: .init(id: "session", title: "Fixture", preview: ""), messages: messages))
  }

  private func send(_ reducer: inout LiveConversationReducer, _ json: String) throws {
    let event = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).object)
    _ = try reducer.apply(event)
  }
}
