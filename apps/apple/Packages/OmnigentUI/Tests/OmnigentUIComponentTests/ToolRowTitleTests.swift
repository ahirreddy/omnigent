#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @MainActor
  @Suite("Tool rows show readable titles", .serialized)
  struct ToolRowTitleTests {
    private func call(_ tool: String, arguments: String) -> Row {
      Row(
        id: "call", role: .tool, text: "",
        activity: Activity(
          kind: .toolCall, title: tool, summary: arguments, status: "completed",
          details: [
            DetailSection(id: "arguments", title: "Arguments", text: arguments, isCode: true)
          ]
        ))
    }

    @Test("a row names the action, not the raw tool")
    func rowShowsTheTitle() throws {
      let cases = [
        ("turn_diff", "{}", "Turn diff", "turn_diff"),
        ("shell", #"{"command":"/bin/bash -lc ls"}"#, "$ ls", "shell"),
        ("apply_patch", #"{"changes":[{"path":"a.swift"}]}"#, "Edit a.swift", "apply_patch"),
      ]
      for (tool, arguments, title, raw) in cases {
        let entry = ToolEntry(call: call(tool, arguments: arguments), result: nil)
        let screen = OffscreenWindow(ToolRowView(entry: entry))
        defer { screen.close() }
        screen.settle()
        #expect(try screen.shows(title), "\(tool)")
        #expect(try !screen.shownText().contains(raw), "\(tool)")
      }
    }
  }
#endif
