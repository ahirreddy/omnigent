import Testing

@testable import OmnigentUIComponents

/// An approval's tool input reads as a diff when it carries edits, and as unescaped JSON
/// otherwise.
@Suite("Tool input preview")
struct ToolInputPreviewTests {
  @Test("apply_patch changes become one diff with the file named")
  func applyPatch() throws {
    let preview = """
      apply_patch({
        "changes": [
          {
            "path": "Omni/iOS/SessionRow.swift",
            "diff": "@@ -8,4 +8,6 @@ struct SessionRow: View {\\n   var body: some View {\\n-    Text(session.title)\\n+    VStack(alignment: .leading) {\\n+      Text(session.title)\\n+    }"
          }
        ]
      })
      """
    let diff = try #require(ToolInputPreview.diff(in: preview))
    #expect(diff.files == ["Omni/iOS/SessionRow.swift"])
    #expect(diff.added == 3)
    #expect(diff.removed == 1)
    #expect(diff.lines.contains { $0.kind == .removed && $0.text == "-    Text(session.title)" })
    #expect(!diff.lines.contains { $0.text.contains("\\n") })
  }

  @Test("Edit's old and new strings become removed and added lines")
  func editStrings() throws {
    let preview = """
      Edit({
        "file_path": "src/auth.rs",
        "old_string": "let a = 1;\\nlet b = 2;",
        "new_string": "let a = 3;"
      })
      """
    let diff = try #require(ToolInputPreview.diff(in: preview))
    #expect(diff.files == ["src/auth.rs"])
    #expect(diff.removed == 2)
    #expect(diff.added == 1)
  }

  @Test("other input keeps its JSON with strings unescaped")
  func plainInput() {
    let preview = """
      web_fetch({
        "url": "https://example.com",
        "prompt": "Line one\\nLine \\"two\\" \\u00e9\\\\"
      })
      """
    #expect(ToolInputPreview.diff(in: preview) == nil)
    #expect(
      ToolInputPreview.unescaped(preview) == """
        web_fetch({
          "url": "https://example.com",
          "prompt": "Line one
        Line "two" \u{e9}\\"
        })
        """)
  }

  @Test("a bare unified diff and non-JSON text")
  func bareText() {
    #expect(ToolInputPreview.diff(in: "@@ -1 +1 @@\n-a\n+b")?.added == 1)
    #expect(ToolInputPreview.diff(in: "just some text") == nil)
    #expect(ToolInputPreview.unescaped("no strings here") == "no strings here")
  }

  @Test("an edit keeps the lines both sides share as context and counts only the change")
  func editContext() {
    let lines = ToolInputPreview.pairLines(
      old: "a\nb\nc\nd\nold\ne\nf\ng", new: "a\nb\nc\nd\nnew\ne\nf\ng")
    #expect(lines == [" c", " d", "-old", "+new", " e", " f"])
    #expect(ToolInputPreview.pairLines(old: "", new: "x") == ["+x"])
  }

  @Test("edit tools read each harness's keys, and MultiEdit's edits under one file")
  func editHarnessKeys() throws {
    let piArguments = #"{"path": "a.ts", "oldText": "x", "newText": "y"}"#
    let piDiff = try #require(ToolEditDiff.diff(tool: "edit", arguments: piArguments, output: nil))
    #expect(piDiff.files == ["a.ts"])
    #expect(piDiff.added == 1 && piDiff.removed == 1)
    let multi = #"""
      {"file_path": "b.swift", "edits": [
        {"old_string": "1", "new_string": "2"}, {"old_string": "3", "new_string": "4\n5"}]}
      """#
    let multiDiff = try #require(
      ToolEditDiff.diff(tool: "MultiEdit", arguments: multi, output: nil))
    #expect(multiDiff.added == 3 && multiDiff.removed == 2)
    #expect(
      ToolEditDiff.diff(
        tool: "Edit", arguments: #"{"old_string": "s", "new_string": "s"}"#, output: nil) == nil)
  }

  @Test("a write counts its lines as added only when it created the file")
  func writeContent() throws {
    let arguments = #"{"file_path": "/tmp/n.md", "content": "one\ntwo"}"#
    let created = try #require(
      ToolEditDiff.diff(
        tool: "Write", arguments: arguments,
        output: "File created successfully at: /tmp/n.md"))
    #expect(created.files == ["/tmp/n.md"])
    #expect(created.added == 2)
    #expect(created.lines.last == DiffSummary.Line(kind: .added, text: "+two"))
    let overwritten = try #require(
      ToolEditDiff.diff(tool: "sys_os_write", arguments: arguments, output: nil))
    #expect(overwritten.added == 0)
    #expect(overwritten.lines.last == DiffSummary.Line(kind: .context, text: "two"))
    #expect(ToolEditDiff.diff(tool: "Write", arguments: "{\"content\": \"tr", output: nil) == nil)
  }
}
