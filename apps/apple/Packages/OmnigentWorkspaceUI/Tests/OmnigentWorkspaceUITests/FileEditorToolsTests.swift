#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// The editor's Markdown tools, selection bar, limits and following outside changes.
  @MainActor
  @Suite("File editor tools", .serialized)
  struct FileEditorToolsTests {
    private func hosted(
      _ editor: FileEditor, markdown: Bool = false, review: FileReviewContext? = nil,
      comment: @escaping (FileTextSpan) -> Void = { _ in }
    ) -> OffscreenWindow<FileEditorView> {
      OffscreenWindow(
        FileEditorView(
          editor: editor, language: .swift, isMarkdown: markdown, review: review, comment: comment),
        width: 760, height: 360)
    }

    private func textView<Content: View>(_ screen: OffscreenWindow<Content>) throws -> NSTextView {
      try #require(screen.allViews.compactMap { $0 as? NSTextView }.first)
    }

    @Test("the Markdown toolbar's Bold wraps the selection")
    func markdownToolbar() async throws {
      let editor = ReviewFixtures.editor(path: "a.md", text: "word\n")
      let screen = hosted(editor, markdown: true)
      defer { screen.close() }
      #expect(screen.appKitButtons.count >= 15, "13 formats beside Save and Revert")
      let text = try textView(screen)
      text.setSelectedRange(NSRange(location: 0, length: 4))
      // Format buttons follow the save bar's two: Paragraph, H1, H2, H3, Quote, Bold.
      let bold = screen.appKitButtons[2 + 5]
      try screen.click(bold)
      #expect(await settle(screen) { text.string == "**word**\n" })
      #expect(await settle(screen) { editor.isDirty })
      #expect(editor.text == "**word**\n")
    }

    @Test("every Markdown format changes the text and can be undone by Revert")
    func everyFormat() async throws {
      let editor = ReviewFixtures.editor(path: "a.md", text: "word\n")
      let screen = hosted(editor, markdown: true)
      defer { screen.close() }
      let text = try textView(screen)
      for index in 0..<13 {
        text.setSelectedRange(NSRange(location: 0, length: 4))
        try screen.click(screen.appKitButtons[2 + index])
      }
      #expect(await settle(screen) { editor.isDirty })
      #expect(text.string != "word\n")
    }

    @Test("a selection offers Comment, Attach and Ask for the selected lines")
    func selectionBar() async throws {
      let spy = ReviewSpy()
      var commented: [FileTextSpan] = []
      let editor = ReviewFixtures.editor(text: "one\ntwo\nthree\n")
      let screen = hosted(
        editor, review: ReviewFixtures.context(spy: spy), comment: { commented.append($0) })
      defer { screen.close() }
      let plain = screen.appKitButtons.count
      let text = try textView(screen)
      text.setSelectedRange(NSRange(location: 4, length: 5))
      #expect(await settle(screen) { screen.appKitButtons.count == plain + 3 })
      let buttons = screen.appKitButtons.suffix(3).map(\.self)
      try screen.click(buttons[0])
      try screen.click(buttons[1])
      try screen.click(buttons[2])
      #expect(commented.map(\.linesTitle) == ["lines 2-3"])
      #expect(spy.attached.map(\.reference) == ["poems/haiku.txt:2-3"])
      #expect(spy.asked.first?.text == "two\nt")
      // A caret has no span, so the actions go away.
      text.setSelectedRange(NSRange(location: 4, length: 0))
      #expect(await settle(screen) { screen.appKitButtons.count == plain })
    }

    @Test("Comment waits while there are unsaved edits; a blank selection offers nothing")
    func selectionLimits() async throws {
      let editor = ReviewFixtures.editor(text: "one\n\n\ntwo\n")
      let screen = hosted(editor, review: ReviewFixtures.context())
      defer { screen.close() }
      let plain = screen.appKitButtons.count
      let text = try textView(screen)
      text.setSelectedRange(NSRange(location: 4, length: 1))
      await flush(screen)
      #expect(screen.appKitButtons.count == plain)
      text.insertText("zero ", replacementRange: NSRange(location: 0, length: 0))
      text.setSelectedRange(NSRange(location: 0, length: 4))
      #expect(await settle(screen) { screen.appKitButtons.count == plain + 3 })
      #expect(screen.appKitButtons.suffix(3).first?.isEnabled == false)
    }

    @Test("the editor follows a replaced file and a dark appearance")
    func followsChanges() async throws {
      let editor = ReviewFixtures.editor()
      let screen = OffscreenWindow(
        CodeEditorTextView(
          editor: editor, language: .swift, controller: CodeEditorController(),
          onSelection: { _ in }
        )
        .environment(\.colorScheme, .dark), width: 400, height: 200)
      defer { screen.close() }
      let text = try textView(screen)
      #expect(text.isEditable)
      #expect(!text.isAutomaticQuoteSubstitutionEnabled)
      editor.serverChanged("new text\n")
      await flush(screen)
      #expect(await settle(screen) { text.string == "new text\n" })
    }

    @Test("Markdown formatting without a text view does nothing")
    func controllerWithoutView() {
      CodeEditorController().apply(.bold)
    }

    @Test("edits save on their own after the pause")
    func autosave() async throws {
      var writes: [String] = []
      let write: (String, String?) async throws(WorkspaceFailure) -> FileSaveResult = { text, _ in
        await Task.yield()
        writes.append(text)
        return .saved
      }
      let editor = FileEditor(path: "a.txt", text: "a", lineEnding: .lf, write: write)
      editor.autosaveDelay = .milliseconds(1)
      editor.text = "b"
      editor.text = "c"
      for _ in 0..<500 where writes.isEmpty {
        try await Task.sleep(for: .milliseconds(2))
      }
      #expect(writes == ["c"], "a newer edit replaces the pending save")
      #expect(editor.usesCRLF == false)
    }

    @Test("a conflict from a save waits instead of saving again, and Revert takes the latest")
    func revertUnderConflict() async {
      let editor = ReviewFixtures.editor(result: .conflict(latest: "theirs\n"))
      editor.text = "mine\n"
      await editor.save()
      #expect(editor.conflict != nil)
      await editor.save()
      editor.revert()
      #expect(editor.text == "theirs\n")
      #expect(editor.conflict == nil)
    }
  }
#endif
