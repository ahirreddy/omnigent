import Foundation
import XCTest

@testable import NativeLabCore

final class EventHierarchyTests: XCTestCase {
  func testRoutineReceiptsMoveToActivityWithoutChangingHistory() throws {
    let snapshot = try XCTUnwrap(
      EventGalleryFixtures.snapshots.first { $0.id == "gallery-lifecycle" })
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let original = try encoder.encode(snapshot)
    XCTAssertEqual(snapshot.transcriptMessages.map(\.id), ["lifecycle-user", "lifecycle-reply"])
    XCTAssertEqual(
      snapshot.lifecycleMessages.map(\.id), ["lifecycle-created", "lifecycle-deleted"])
    XCTAssertEqual(try encoder.encode(snapshot), original)
    XCTAssertEqual(snapshot.messages.count, 4)
    let restored = try JSONDecoder().decode(ConversationSnapshot.self, from: original)
    XCTAssertEqual(restored, snapshot)
    XCTAssertEqual(restored.lifecycleMessages, snapshot.lifecycleMessages)
  }

  func testFailuresAttachmentsAndTerminalOutputAreNeverQuieted() {
    for kind in [ConversationActivity.Kind.resource, .clientTask, .error, .terminal, .unknown] {
      for status in ["failed", "error", "denied"] {
        let activity = ConversationActivity(
          kind: kind, title: "Failure", summary: "Details", status: status)
        XCTAssertTrue(activity.isFailure)
        XCTAssertFalse(
          ConversationMessage(id: "failure", role: .tool, text: "", activity: activity)
            .isActivityOnly)
      }
    }
    var resource = ConversationMessage(
      id: "file", role: .tool, text: "File ready",
      activity: .init(kind: .resource, title: "File created", summary: "Notes"))
    resource.attachments = [.init(id: "a", kind: .file, title: "notes.txt", reference: "file-1")]
    XCTAssertFalse(resource.isActivityOnly)
    let output = ConversationMessage(
      id: "output", role: .tool, text: "Build succeeded",
      activity: .init(
        kind: .terminal, title: "Terminal output", summary: "Build succeeded", status: "completed"))
    XCTAssertFalse(output.isActivityOnly)
  }

  func testOnlyFinishedClientBookkeepingIsQuieted() {
    for status in ["cancelled", "canceled", "completed"] {
      XCTAssertTrue(
        ConversationActivity(kind: .clientTask, title: "Task", summary: "", status: status)
          .isRoutineLifecycle)
    }
    for status in ["desktop_required", "running", "failed"] {
      XCTAssertFalse(
        ConversationActivity(kind: .clientTask, title: "Task", summary: "", status: status)
          .isRoutineLifecycle)
    }
  }

  func testHistoryAndStreamUseSameLifecycleProjection() throws {
    let event = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(
        #"{"type":"response.output_item.done","item":{"id":"receipt","type":"resource_event","event_type":"session.resource.deleted","resource_type":"terminal","resource_id":"terminal-main","status":"completed"}}"#
          .utf8))
    let fields = try XCTUnwrap(event.object)
    let item = try XCTUnwrap(fields["item"]?.object)
    let historical = try XCTUnwrap(ItemWire(payload: item).message())
    var reducer = makeReducer()
    _ = try reducer.apply(fields)
    XCTAssertEqual(reducer.snapshot.lifecycleMessages, [historical])
    XCTAssertTrue(reducer.snapshot.transcriptMessages.isEmpty)
    XCTAssertEqual(reducer.snapshot.messages, [historical])
  }

  func testStopMarksOnlyCurrentReplyAndCompletionIsQuiet() throws {
    for terminal in ["response.cancelled", "session.interrupted", "response.completed"] {
      var reducer = makeReducer()
      reducer.snapshot.messages = [
        .init(id: "older", role: .assistant, text: "Earlier answer", responseID: "previous")
      ]
      _ = try reducer.apply([
        "type": .string("response.created"), "response": .object(["id": .string("r1")]),
      ])
      _ = try reducer.apply([
        "type": .string("response.output_text.delta"), "delta": .string("Partial answer"),
      ])
      _ = try reducer.apply(["type": .string(terminal), "response_id": .string("r1")])
      XCTAssertEqual(reducer.snapshot.messages.count, 2)
      XCTAssertFalse(reducer.snapshot.messages[1].isStreaming)
      XCTAssertNil(reducer.snapshot.messages[0].interrupted)
      XCTAssertEqual(
        reducer.snapshot.messages[1].interrupted == true, terminal != "response.completed")
      XCTAssertEqual(reducer.snapshot.transcriptMessages[1].text, "Partial answer")
    }
  }

  private func makeReducer() -> LiveConversationReducer {
    LiveConversationReducer(
      snapshot: .init(
        revision: 1, session: .init(id: "s1", title: "Fixture", preview: ""), messages: []))
  }
}
