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
}
