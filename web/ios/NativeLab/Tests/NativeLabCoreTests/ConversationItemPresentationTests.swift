import Foundation
import XCTest

@testable import NativeLabCore

final class ConversationItemPresentationTests: XCTestCase {
  func testLegacyConversationMessagesDecodeWithoutNewFields() throws {
    let legacy = #"{"id":"m1","role":"assistant","text":"Hello","isStreaming":false}"#
    let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(legacy.utf8))
    XCTAssertEqual(message.text, "Hello")
    XCTAssertNil(message.activity)
    XCTAssertNil(message.attachments)
    XCTAssertNil(message.responseID)
    XCTAssertNil(message.callID)
    XCTAssertNil(message.interrupted)
    XCTAssertNil(message.author)
    XCTAssertNil(message.agent)
    XCTAssertEqual(
      try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(message)),
      message)
  }

  func testAttachmentDescriptorsPreserveTextWithoutEmbeddingOrFetchingContent() throws {
    let item = try decode(
      #"{"id":"m1","type":"message","role":"user","response_id":"r1","content":[{"type":"input_text","text":"Inspect these"},{"type":"input_image","file_id":"file1","filename":"diagram.png"},{"type":"input_file","file_id":"file2","filename":"notes.pdf","mime_type":"application/pdf"},{"type":"input_image","image_url":"data:image/png;base64,PRIVATE_BYTES"},{"type":"input_audio","source":{"data":"PRIVATE_AUDIO","media_type":"audio/wav"}}]}"#
    )
    XCTAssertEqual(item.text, "Inspect these")
    XCTAssertEqual(item.responseID, "r1")
    XCTAssertEqual(item.attachments?.map(\.kind), [.image, .file, .image, .audio])
    XCTAssertEqual(item.attachments?[0].reference, "file1")
    XCTAssertEqual(item.attachments?[1].mimeType, "application/pdf")
    XCTAssertEqual(item.attachments?[2].isEmbedded, true)
    XCTAssertNil(item.attachments?[2].reference)
    XCTAssertEqual(item.attachments?[3].isEmbedded, true)
    XCTAssertFalse(try encoded(item).contains("PRIVATE_"))
  }

  func testRefusalsAndInterruptedMessagesRemainVisible() throws {
    let item = try decode(
      #"{"id":"m1","type":"message","role":"assistant","interrupted":true,"content":[{"type":"output_text","text":"Partial response"},{"type":"refusal","refusal":"I cannot provide that."}]}"#
    )
    XCTAssertEqual(item.text, "Partial response\nI cannot provide that.")
    XCTAssertEqual(item.interrupted, true)
  }

  func testMessageAttributionPreservesHumanAndAgentIdentity() throws {
    let user = try decode(
      #"{"id":"u1","type":"message","role":"user","created_by":"person@example.test","content":"Question"}"#
    )
    let assistant = try decode(
      #"{"id":"a1","type":"message","role":"assistant","model":"child-agent","content":"Answer"}"#)
    XCTAssertEqual(user.author, "person@example.test")
    XCTAssertNil(user.agent)
    XCTAssertEqual(assistant.agent, "child-agent")
    XCTAssertNil(assistant.author)
  }

  func testReasoningNeverFallsBackToRawOrEncryptedContent() throws {
    let item = try decode(
      #"{"id":"r1","type":"reasoning","summary":[{"type":"summary_text","text":"Checked the available options."},{"type":"reasoning_text","text":"HIDDEN_SUMMARY_BLOCK"}],"content":[{"type":"reasoning_text","text":"HIDDEN_REASONING"}],"encrypted_content":"ENCRYPTED_SECRET"}"#
    )
    XCTAssertEqual(item.activity?.summary, "Checked the available options.")
    XCTAssertEqual(item.activity?.details.map(\.text), ["Checked the available options."])
    XCTAssertFalse(try encoded(item).contains("HIDDEN_"))
    XCTAssertFalse(try encoded(item).contains("ENCRYPTED_SECRET"))
    let withoutSummary = try decode(
      #"{"id":"r2","type":"reasoning","content":[{"type":"text","text":"PRIVATE"}]}"#)
    XCTAssertEqual(withoutSummary.activity?.summary, "No public reasoning summary was provided.")
    XCTAssertFalse(try encoded(withoutSummary).contains("PRIVATE"))
  }

  func testNestedUnknownPayloadSanitizesCredentialsAndPrivateReasoning() throws {
    let item = try decode(
      #"{"id":"future1","type":"future_result","summary":"Useful future activity","payload":{"result":"Kept result","headers":{"Authorization":"PRIVATE_AUTH","X-Api-Key":"PRIVATE_KEY"},"nested":{"password":"PRIVATE_PASSWORD","encrypted_content":"PRIVATE_ENCRYPTED","content":[{"type":"reasoning_text","text":"PRIVATE_THOUGHTS"},{"type":"output_text","text":"Public output"}]},"image_data":"PRIVATE_IMAGE"}}"#
    )
    XCTAssertEqual(item.activity?.kind, .unknown)
    let result = try encoded(item)
    XCTAssertTrue(result.contains("Kept result"))
    XCTAssertTrue(result.contains("Public output"))
    XCTAssertFalse(result.contains("PRIVATE_"))
    XCTAssertFalse(result.contains("preview not supported"))
  }

  func testJSONEncodedToolArgumentsAndOutputAreSanitized() throws {
    let call = try decode(
      #"{"id":"call1","type":"function_call","call_id":"c1","response_id":"r1","name":"request","arguments":"{\"query\":\"weather\",\"api_key\":\"PRIVATE_KEY\"}"}"#
    )
    XCTAssertEqual(call.callID, "c1")
    XCTAssertEqual(call.responseID, "r1")
    XCTAssertTrue(call.text.contains("weather"))
    XCTAssertFalse(try encoded(call).contains("PRIVATE_KEY"))
    let output = try decode(
      #"{"id":"output1","type":"function_call_output","call_id":"c1","output":"{\"answer\":\"Clear skies\",\"refresh_token\":\"PRIVATE_TOKEN\"}"}"#
    )
    XCTAssertTrue(output.text.contains("Clear skies"))
    XCTAssertFalse(try encoded(output).contains("PRIVATE_TOKEN"))
  }

  func testIncompleteStructuredArgumentsNeverExposePrivateValues() {
    let value = JSONValue.string("{\"encrypted_content\":\"PRIVATE_PARTIAL")
    XCTAssertEqual(value.safeDisplayText, "[Structured payload is incomplete]")
    XCTAssertEqual(
      JSONValue.string("[Tool output unavailable]").safeDisplayText, "[Tool output unavailable]")
  }

  func testUnknownPayloadsAreBoundedByCharactersDepthAndEntryCount() throws {
    let longText = String(repeating: "visible output ", count: 10_000)
    var nested: JSONValue = .string("UNREACHABLE_DEPTH")
    for _ in 0..<20 { nested = .object(["next": nested]) }
    let payload: [String: JSONValue] = [
      "id": .string("large"), "type": .string("future_item"), "body": .string(longText),
      "nested": nested, "items": .array((0..<1_000).map { .string("entry-\($0)") }),
    ]
    let item = try XCTUnwrap(ItemWire(payload: payload).message())
    let details = try XCTUnwrap(item.activity?.details.first?.text)
    XCTAssertLessThanOrEqual(details.count, 16_012)
    XCTAssertTrue(details.contains("Truncated"))
    XCTAssertFalse(details.contains("entry-999"))
    XCTAssertFalse(details.contains("UNREACHABLE_DEPTH"))
  }

  func testMessagePrivateBlocksDoNotBecomeUnknownContentCards() throws {
    let item = try decode(
      #"{"id":"m1","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"PRIVATE"},{"type":"redacted_thinking","data":"PRIVATE"},{"type":"reasoning_text","text":"PRIVATE"},{"type":"output_text","text":"Visible"}]}"#
    )
    XCTAssertEqual(item.text, "Visible")
    XCTAssertNil(item.activity)
    XCTAssertFalse(try encoded(item).contains("PRIVATE"))
  }

  func testNewContentBlocksHaveUsefulSafeDetails() throws {
    let item = try decode(
      #"{"id":"m1","type":"message","role":"assistant","content":[{"type":"future_chart","caption":"Quarterly totals","values":[1,2,3],"secret":"PRIVATE"}]}"#
    )
    XCTAssertEqual(item.activity?.kind, .unknown)
    XCTAssertTrue(item.activity?.details.first?.text.contains("Quarterly totals") == true)
    XCTAssertFalse(try encoded(item).contains("PRIVATE"))
  }

  private func decode(_ json: String) throws -> ConversationMessage {
    try XCTUnwrap(JSONDecoder().decode(ItemWire.self, from: Data(json.utf8)).message())
  }

  private func encoded(_ message: ConversationMessage) throws -> String {
    String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
  }
}
