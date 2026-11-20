import Testing

@testable import OmnigentUIComponents

/// A tool call's JSON as the web's Fields view labels it.
@Suite("Transcript: tool fields")
struct ToolFieldsTests {
  @Test func anObjectBecomesLabeledFieldsInKeyOrder() {
    let fields = ToolFieldValue.fields(
      json: #"{"path":"a.swift","limit":20,"recursive":true,"note":null,"tags":["x","y"]}"#)
    #expect(fields.map(\.key) == ["limit", "note", "path", "recursive", "tags"])
    #expect(fields.first?.value == .scalar("20"))
    #expect(fields.dropFirst().first?.value == .empty)
    #expect(fields.dropFirst(3).first?.value == .scalar("true"))
    #expect(fields.last?.value == .scalar("x, y"))
  }

  @Test func nestingAndListsOfObjectsStayReadable() {
    let fields = ToolFieldValue.fields(json: #"{"options":{"depth":2},"items":[{"a":1}]}"#)
    guard case .code(let code) = fields.first?.value else {
      Issue.record("a list of objects shows as JSON")
      return
    }
    #expect(code.contains("\"a\" : 1"))
    #expect(fields.last?.value == .fields([ToolField(key: "depth", value: .scalar("2"))]))
  }

  @Test func onlyAnObjectThatFitsIsFields() {
    #expect(ToolFieldValue.fields(json: "plain text").isEmpty)
    #expect(ToolFieldValue.fields(json: "[1, 2]").isEmpty)
    let long = "{\"text\":\"" + String(repeating: "x", count: ToolFieldValue.fieldLimit) + "\"}"
    #expect(ToolFieldValue.fields(json: long).isEmpty)
  }
}
