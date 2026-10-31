import Foundation
import XCTest

@testable import NativeLabCore

final class LiveConversationReducerTests: XCTestCase {
  func testNativeRepliesStreamAfterWrapperCompletionAcrossConsecutiveTurns() throws {
    var reducer = makeReducer()
    for turn in 1...2 {
      _ = try reducer.apply(
        event(
          "{\"type\":\"response.in_progress\",\"response\":{\"id\":\"wrapper\(turn)\"}}"))
      _ = try reducer.apply(
        event(
          "{\"type\":\"response.completed\",\"response\":{\"id\":\"wrapper\(turn)\",\"output\":[]}}"
        ))
      _ = try reducer.apply(event(#"{"type":"session.status","status":"idle"}"#))
      _ = try reducer.apply(
        event(
          "{\"type\":\"response.output_text.delta\",\"message_id\":\"native\(turn)\",\"index\":0,\"delta\":\"Hello \(turn)\"}"
        ))
      XCTAssertEqual(reducer.snapshot.messages.last?.text, "Hello \(turn)")
      XCTAssertEqual(reducer.snapshot.messages.last?.isStreaming, true)
      XCTAssertEqual(reducer.snapshot.session.status, .running)
      _ = try reducer.apply(
        event(
          "{\"type\":\"response.output_text.delta\",\"message_id\":\"native\(turn)\",\"index\":1,\"delta\":\" world\",\"final\":true}"
        ))
      XCTAssertEqual(reducer.snapshot.messages.last?.text, "Hello \(turn) world")
      _ = try reducer.apply(
        event(
          "{\"type\":\"response.output_item.done\",\"item\":{\"id\":\"saved\(turn)\",\"response_id\":\"native-turn\(turn)\",\"type\":\"message\",\"role\":\"assistant\",\"content\":\"Hello \(turn) world\"}}"
        ))
      _ = try reducer.apply(
        event(
          "{\"type\":\"response.output_text.delta\",\"message_id\":\"native\(turn)\",\"index\":2,\"delta\":\"late\"}"
        ))
      XCTAssertEqual(reducer.snapshot.messages.count, turn)
      XCTAssertEqual(reducer.snapshot.messages.last?.id, "saved\(turn)")
    }
  }

  func testWrapperCompletionDoesNotSealNativeTextAlreadyStreaming() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(event(#"{"type":"response.in_progress","response":{"id":"wrapper"}}"#))
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native","index":0,"delta":"Hello"}"#))
    _ = try reducer.apply(
      event(#"{"type":"response.completed","response":{"id":"wrapper","output":[]}}"#))
    XCTAssertTrue(try XCTUnwrap(reducer.snapshot.messages.last).isStreaming)
    XCTAssertEqual(reducer.snapshot.session.status, .running)
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native","index":1,"delta":" world"}"#))
    XCTAssertEqual(reducer.snapshot.messages.last?.text, "Hello world")
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_item.done","item":{"id":"saved","response_id":"native-turn","type":"message","role":"assistant","content":"Hello world"}}"#
      ))
    XCTAssertEqual(reducer.snapshot.messages.map(\.id), ["saved"])
  }

  func testNativeInterruptionRejectsLateTextButNextTurnStillStreams() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(
      event(#"{"type":"session.status","status":"running","response_id":"native-turn"}"#))
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native","index":0,"delta":"Partial"}"#)
    )
    _ = try reducer.apply(
      event(#"{"type":"session.interrupted","data":{"response_id":"native-turn"}}"#))
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native","index":1,"delta":" late"}"#))
    XCTAssertEqual(reducer.snapshot.messages.last?.text, "Partial")
    XCTAssertEqual(reducer.snapshot.messages.last?.interrupted, true)
    XCTAssertEqual(reducer.snapshot.messages.last?.isStreaming, false)
    _ = try reducer.apply(event(#"{"type":"response.in_progress","response":{"id":"wrapper2"}}"#))
    _ = try reducer.apply(event(#"{"type":"response.completed","response":{"id":"wrapper2"}}"#))
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native","index":2,"delta":" still late"}"#
      ))
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native2","index":0,"delta":"Next reply"}"#
      ))
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["Partial", "Next reply"])
    XCTAssertEqual(reducer.snapshot.messages.last?.isStreaming, true)
  }

  func testOrdinaryResponseDeltasRemainBlockedAfterCompletion() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(event(#"{"type":"response.in_progress","response":{"id":"r1"}}"#))
    _ = try reducer.apply(event(#"{"type":"response.output_text.delta","delta":"Hello"}"#))
    _ = try reducer.apply(event(#"{"type":"response.completed","response":{"id":"r1"}}"#))
    let snapshot = reducer.snapshot
    _ = try reducer.apply(event(#"{"type":"response.output_text.delta","delta":" late"}"#))
    XCTAssertEqual(reducer.snapshot, snapshot)
  }

  func testConfigurationEventsRetainUnknownValuesAndDistinguishNullFromMissing() throws {
    var reducer = makeReducer()
    reducer.snapshot.session.configuration = .demo
    let original = reducer.snapshot.session.configuration
    for payload in [
      #"{"type":"session.model"}"#,
      #"{"type":"session.reasoning_effort","reasoning_effort":42}"#,
      #"{"type":"session.model","conversation_id":"other","model":"wrong"}"#,
    ] {
      let effects = try reducer.apply(event(payload))
      XCTAssertFalse(effects.changed)
      XCTAssertEqual(reducer.snapshot.session.configuration, original)
    }
    let changed = try reducer.apply(event(#"{"type":"session.model","model":"unknown-raw-model"}"#))
    XCTAssertTrue(changed.changed)
    XCTAssertTrue(changed.reconcile)
    XCTAssertEqual(reducer.snapshot.session.configuration?.modelLabel, "unknown-raw-model")
    _ = try reducer.apply(event(#"{"type":"session.reasoning_effort","reasoning_effort":"high"}"#))
    XCTAssertEqual(reducer.snapshot.session.configuration?.effortLabel, "High")
    _ = try reducer.apply(event(#"{"type":"session.reasoning_effort","reasoning_effort":null}"#))
    XCTAssertEqual(reducer.snapshot.session.configuration?.effortLabel, "Harness default")
    _ = try reducer.apply(event(#"{"type":"session.model","model":null}"#))
    XCTAssertEqual(reducer.snapshot.session.configuration?.modelLabel, "Harness default")
  }

  func testCatalogAndHarnessEventsRequestAuthoritativeReconciliation() throws {
    var reducer = makeReducer()
    reducer.snapshot.session.configuration = .demo
    for type in ["session.model_options", "session.agent_changed"] {
      let effects = try reducer.apply(["type": .string(type)])
      XCTAssertTrue(effects.reconcile)
      XCTAssertFalse(effects.changed)
    }
    var authoritative = reducer.snapshot
    authoritative.session.configuration?.agentID = "new-clone"
    authoritative.session.configuration?.harness = "future-harness"
    authoritative.session.configuration?.models = []
    reducer.reconcile(with: authoritative)
    XCTAssertEqual(reducer.snapshot.session.configuration, authoritative.session.configuration)
  }

  func testPersistedErrorItemRetainsCauseWhenReplayedAndDoesNotDuplicate() throws {
    var reducer = makeReducer()
    let failure = try event(
      #"{"type":"response.output_item.done","item":{"id":"error_1","type":"error","data":{"source":"execution","code":"runner_failed_to_start","message":"Runner unavailable. See the host logs."}}}"#
    )
    _ = try reducer.apply(failure)
    _ = try reducer.apply(failure)
    XCTAssertEqual(reducer.snapshot.messages.count, 1)
    XCTAssertEqual(reducer.snapshot.messages.first?.id, "error_1")
    XCTAssertEqual(reducer.snapshot.messages.first?.role, .tool)
    XCTAssertEqual(
      reducer.snapshot.messages.first?.text,
      "Error (runner_failed_to_start): Runner unavailable. See the host logs.")
    XCTAssertFalse(try XCTUnwrap(reducer.snapshot.messages.first).isStreaming)
  }

  func testInPlaceHydrationPreservesPrefixAndNativeChunkDeduplication() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native1","index":0,"delta":"Hello"}"#))
    var metadata = makeReducer().snapshot
    metadata.session.title = "Renamed while streaming"
    reducer.reconcile(with: metadata)
    XCTAssertEqual(reducer.snapshot.session.title, "Renamed while streaming")
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["Hello"])
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native1","index":0,"delta":"duplicate"}"#
      ))
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native1","index":1,"delta":" world"}"#)
    )
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["Hello world"])
  }

  func testOlderHistoryPrefixCannotRetireNewerStreamingText() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native","index":0,"delta":"Hello world"}"#
      ))
    reducer.reconcile(
      with: makeReducer(messages: [
        ConversationMessage(id: "saved", role: .assistant, text: "Hello")
      ]).snapshot)
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["Hello world"])
    XCTAssertEqual(reducer.snapshot.messages.last?.isStreaming, true)
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native","index":1,"delta":" again"}"#))
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["Hello world again"])
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_item.done","item":{"id":"saved","type":"message","role":"assistant","content":"Hello world again"}}"#
      ))
    XCTAssertEqual(reducer.snapshot.messages.map(\.id), ["saved"])
    XCTAssertEqual(reducer.snapshot.messages.last?.isStreaming, false)
  }

  func testInPlaceHydrationPreservesOrdinaryResponsePrefixAndPreviewPosition() throws {
    let user = ConversationMessage(id: "user", role: .user, text: "Question")
    var reducer = makeReducer(messages: [user])
    _ = try reducer.apply(event(#"{"type":"response.created","response":{"id":"response1"}}"#))
    _ = try reducer.apply(event(#"{"type":"response.output_text.delta","delta":"Hello"}"#))
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_item.done","item":{"id":"tool","type":"function_call","name":"example","arguments":"{}"}}"#
      ))
    let tool = try XCTUnwrap(reducer.snapshot.messages.last)
    reducer.reconcile(with: makeReducer(messages: [user, tool]).snapshot)
    _ = try reducer.apply(event(#"{"type":"response.output_text.delta","delta":" world"}"#))
    XCTAssertEqual(
      reducer.snapshot.messages.map(\.id), ["user", "live:response:response1:0", "tool"])
    XCTAssertEqual(reducer.snapshot.messages[1].text, "Hello world")
  }

  func testHydrationCommitRetiresMatchingPreviewBeforeBufferedFinalItem() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native1","index":0,"delta":"Hello"}"#))
    let committed = ConversationMessage(id: "persisted", role: .assistant, text: "Hello world")
    reducer.reconcile(with: makeReducer(messages: [committed]).snapshot)
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_item.done","item":{"id":"persisted","type":"message","role":"assistant","content":"Hello world"}}"#
      ))
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native1","index":1,"delta":" world"}"#)
    )
    XCTAssertEqual(reducer.snapshot.messages, [committed])
  }

  func testRealReconnectUsesFreshReducerSoInflightReplayDoesNotDoublePrefix() throws {
    var old = makeReducer()
    _ = try old.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native1","index":4,"delta":"stale prefix"}"#
      ))
    var reconnected = makeReducer()
    _ = try reconnected.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native1","index":4,"delta":"authoritative prefix"}"#
      ))
    _ = try reconnected.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native1","index":5,"delta":" tail"}"#))
    XCTAssertEqual(reconnected.snapshot.messages.map(\.text), ["authoritative prefix tail"])
  }

  func testByteFramingRetainsEmptyLinesCRLFAndUTF8() throws {
    var parser = ServerSentEventByteParser()
    let stream = "\u{FEFF}event: test\r\ndata: héllo 🌎\r\n\r\ndata: second\r\rdata: third\n\n"
    var frames: [ServerSentEvent] = []
    for byte in stream.utf8 {
      if let frame = try parser.consume(byte) { frames.append(frame) }
    }
    XCTAssertEqual(frames.map(\.data), ["héllo 🌎", "second", "third"])
    XCTAssertEqual(frames.first?.event, "test")
  }
  func testSSEParserHandlesCommentsMultilineAndBoundaries() throws {
    var parser = ServerSentEventParser()
    XCTAssertNil(try parser.consume(": keepalive"))
    XCTAssertNil(try parser.consume("event: response.output_text.delta"))
    XCTAssertNil(try parser.consume("data: {\"delta\":"))
    XCTAssertNil(try parser.consume("data: \"hello\"}"))
    XCTAssertEqual(
      try parser.consume(""),
      ServerSentEvent(event: "response.output_text.delta", data: "{\"delta\":\n\"hello\"}"))
    XCTAssertNil(try parser.consume(""))
    XCTAssertNil(try parser.consume("data: [DONE]"))
    XCTAssertEqual(try parser.consume("")?.data, "[DONE]")
  }

  func testNativeDeltasDeduplicateIndexAndCommitRetiresPreview() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native1","index":0,"delta":"Hel"}"#))
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native1","index":0,"delta":"duplicate"}"#
      ))
    _ = try reducer.apply(
      event(#"{"type":"response.output_text.delta","message_id":"native1","index":1,"delta":"lo"}"#)
    )
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["Hello"])
    XCTAssertTrue(reducer.snapshot.messages[0].isStreaming)
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_item.done","item":{"id":"persisted1","type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}"#
      ))
    XCTAssertEqual(reducer.snapshot.messages.map(\.id), ["persisted1"])
    XCTAssertFalse(reducer.snapshot.messages[0].isStreaming)
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"native1","index":2,"delta":"late"}"#))
    XCTAssertEqual(reducer.snapshot.messages.count, 1)
  }

  func testDuplicateCommittedItemCannotDiscardNewerPreview() throws {
    var reducer = makeReducer(messages: [
      ConversationMessage(id: "old", role: .assistant, text: "Old reply")
    ])
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"new","index":0,"delta":"New streaming reply"}"#
      ))
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_item.done","item":{"id":"old","type":"message","role":"assistant","content":"Old reply"}}"#
      ))
    XCTAssertEqual(reducer.snapshot.messages.map(\.id), ["old", "live:new"])
    XCTAssertEqual(reducer.snapshot.messages.last?.text, "New streaming reply")
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_text.delta","message_id":"new","index":1,"delta":" continues"}"#)
    )
    XCTAssertEqual(reducer.snapshot.messages.last?.text, "New streaming reply continues")
  }

  func testOrdinaryDeltaSegmentsBecomePersistedItemsWithoutDuplicates() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(event(#"{"type":"response.created","response":{"id":"response1"}}"#))
    _ = try reducer.apply(event(#"{"type":"response.output_text.delta","delta":"First"}"#))
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_item.done","item":{"id":"item1","type":"message","role":"assistant","content":"First"}}"#
      ))
    _ = try reducer.apply(event(#"{"type":"response.output_text.delta","delta":"Second"}"#))
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_item.done","item":{"id":"item2","type":"message","role":"assistant","content":"Second"}}"#
      ))
    XCTAssertEqual(reducer.snapshot.messages.map(\.id), ["item1", "item2"])
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["First", "Second"])
  }

  func testConsumedInputKeepsStableIDAndPendingCorrelation() throws {
    var reducer = makeReducer()
    let frame = try event(
      #"{"type":"session.input.consumed","data":{"item_id":"user1","type":"message","data":{"role":"user","content":[{"type":"input_text","text":"Question"}]},"cleared_pending_id":"pending1"}}"#
    )
    let effects = try reducer.apply(frame)
    _ = try reducer.apply(frame)
    XCTAssertEqual(reducer.snapshot.messages.map(\.id), ["user1"])
    XCTAssertEqual(effects.consumedItemID, "user1")
    XCTAssertEqual(effects.consumedPendingID, "pending1")
  }

  func testHiddenContextNeverAppearsFromStream() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(
      event(
        #"{"type":"session.input.consumed","data":{"item_id":"meta1","type":"message","data":{"role":"user","is_meta":true,"content":"Hidden context"}}}"#
      ))
    _ = try reducer.apply(
      event(
        #"{"type":"response.output_item.done","item":{"id":"meta2","type":"message","role":"assistant","is_meta":true,"content":"Hidden context"}}"#
      ))
    XCTAssertTrue(reducer.snapshot.messages.isEmpty)
  }

  func testApprovalAndSingleFieldQuestionUseOriginatingSession() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(
      event(
        #"{"type":"response.elicitation_request","elicitation_id":"ask1","params":{"target_session_id":"child1","message":"Choose","requestedSchema":{"type":"object","properties":{"answer":{"type":"string","enum":["Yes","No"]}}}}}"#
      ))
    let decision = try XCTUnwrap(reducer.snapshot.pendingDecisions.first)
    XCTAssertEqual(decision.targetSessionID, "child1")
    XCTAssertEqual(decision.options, ["Yes", "No"])
    XCTAssertEqual(decision.answerKey, "answer")
    XCTAssertNil(decision.unsupportedReason)
    XCTAssertEqual(reducer.snapshot.session.status, .needsResponse)
    _ = try reducer.apply(
      event(#"{"type":"response.elicitation_resolved","elicitation_id":"ask1"}"#))
    XCTAssertTrue(reducer.snapshot.pendingDecisions.isEmpty)
  }

  func testMultiFieldFormsUseTypedFieldsInsteadOfBinaryApprovals() throws {
    let decision = try ElicitationWire(
      value: .object(
        event(
          #"{"elicitation_id":"ask1","params":{"message":"Name and count","requestedSchema":{"properties":{"name":{"type":"string"},"count":{"type":"integer"}}}}}"#
        )), sessionID: "parent"
    ).decision
    XCTAssertNil(decision.unsupportedReason)
    XCTAssertTrue(decision.options.isEmpty)
    XCTAssertEqual(decision.form?.fields.map(\.key), ["count", "name"])
    XCTAssertEqual(decision.form?.fields.map(\.kind), [.integer, .text])
  }

  func testProviderFailureEndsSpinnerAndRetainsReadableError() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(event(#"{"type":"response.created","response":{"id":"r1"}}"#))
    _ = try reducer.apply(event(#"{"type":"response.output_text.delta","delta":"Partial"}"#))
    let effects = try reducer.apply(
      event(
        #"{"type":"response.failed","response":{"id":"r1","error":{"code":"codex_reauth_required","message":"Sign in again"}}}"#
      ))
    XCTAssertEqual(reducer.snapshot.session.status, .idle)
    XCTAssertEqual(effects.error, "Sign in again")
    XCTAssertEqual(reducer.snapshot.session.failureMessage, "Sign in again")
    XCTAssertTrue(effects.reconcile)
    XCTAssertFalse(reducer.snapshot.messages[0].isStreaming)
  }

  func testStaleResponseCompletionCannotStopNewerReply() throws {
    var reducer = makeReducer()
    _ = try reducer.apply(event(#"{"type":"response.created","response":{"id":"new"}}"#))
    let effects = try reducer.apply(
      event(#"{"type":"response.completed","response":{"id":"old"}}"#))
    XCTAssertFalse(effects.changed)
    XCTAssertFalse(effects.reconcile)
    XCTAssertEqual(reducer.snapshot.session.status, .running)
  }

  func testRehydrationDiscardsOldPreviewsAndPendingDecisions() throws {
    var old = makeReducer()
    _ = try old.apply(
      event(#"{"type":"response.output_text.delta","message_id":"old","index":0,"delta":"stale"}"#))
    _ = try old.apply(
      event(
        #"{"type":"response.elicitation_request","elicitation_id":"ask1","params":{"message":"Approve?","requestedSchema":{}}}"#
      ))
    let fresh = LiveConversationReducer(
      snapshot: makeReducer(messages: [
        ConversationMessage(id: "committed", role: .assistant, text: "Completed")
      ]).snapshot)
    XCTAssertEqual(fresh.snapshot.messages.map(\.id), ["committed"])
    XCTAssertTrue(fresh.snapshot.pendingDecisions.isEmpty)
  }

  private func makeReducer(messages: [ConversationMessage] = []) -> LiveConversationReducer {
    LiveConversationReducer(
      snapshot: ConversationSnapshot(
        revision: 1,
        session: SessionSummary(id: "session1", title: "Session", preview: "", permissionLevel: 4),
        messages: messages))
  }

  private func event(_ text: String) throws -> [String: JSONValue] {
    try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).object)
  }
}
