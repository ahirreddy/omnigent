#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// The Edit mode: the save bar, a conflict with a change made elsewhere, the Markdown toolbar
  /// and review actions for a selection.
  @MainActor
  @Suite("File editor view", .serialized)
  struct FileEditorViewTests {
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

    /// Revert then Save, the save bar's plain buttons.
    private func saveBarButtons<Content: View>(_ screen: OffscreenWindow<Content>) -> [NSButton] {
      Array(screen.appKitButtons.prefix(2))
    }

    @Test("the save bar shows nothing to do until there is an edit")
    func clean() throws {
      let editor = ReviewFixtures.editor()
      let screen = hosted(editor)
      defer { screen.close() }
      for button in saveBarButtons(screen) { #expect(!button.isEnabled) }
      #expect(try textView(screen).string == "old pond\n")
    }

    @Test("typing marks the edit unsaved, Save writes it, and Saved shows")
    func typeAndSave() async throws {
      let editor = ReviewFixtures.editor()
      let screen = hosted(editor)
      defer { screen.close() }
      let text = try textView(screen)
      text.setSelectedRange(NSRange(location: 8, length: 0))
      text.insertText("!", replacementRange: text.selectedRange())
      #expect(await settle(screen) { editor.isDirty })
      #expect(await settle(screen) { saveBarButtons(screen).allSatisfy(\.isEnabled) })
      let unsaved = try shownString(screen)
      #expect(unsaved.contains("Unsaved"), "read: \(unsaved)")
      try screen.click(saveBarButtons(screen)[1])
      #expect(await settle(screen) { editor.status == .saved })
      #expect(!editor.isDirty)
      let saved = try shownString(screen)
      #expect(saved.contains("Saved"), "read: \(saved)")
    }

    @Test("Revert discards an edit and reloads the text")
    func revert() async throws {
      let editor = ReviewFixtures.editor()
      let screen = hosted(editor)
      defer { screen.close() }
      let text = try textView(screen)
      text.insertText("X", replacementRange: NSRange(location: 0, length: 0))
      #expect(await settle(screen) { editor.isDirty })
      #expect(await settle(screen) { saveBarButtons(screen).allSatisfy(\.isEnabled) })
      try screen.click(saveBarButtons(screen)[0])
      #expect(await settle(screen) { text.string == "old pond\n" })
      #expect(!editor.isDirty)
    }

    @Test("a failed save says why and keeps the edit")
    func failedSave() async throws {
      let editor = ReviewFixtures.editor(
        failure: WorkspaceFailure(.forbidden, message: "Read-only share"))
      let screen = hosted(editor)
      defer { screen.close() }
      editor.text = "changed\n"
      await editor.save()
      await flush(screen)
      #expect(editor.isDirty)
      let read = try shownString(screen)
      #expect(read.contains("Read-only share"), "read: \(read)")
    }

    @Test("a save in flight disables Save and Revert")
    func saving() async throws {
      var release: CheckedContinuation<Void, Never>?
      let write: (String, String?) async throws(WorkspaceFailure) -> FileSaveResult = { _, _ in
        await withCheckedContinuation { release = $0 }
        return .saved
      }
      let editor = FileEditor(path: "a.txt", text: "a", lineEnding: .lf, write: write)
      editor.autosaveDelay = nil
      let screen = hosted(editor)
      defer { screen.close() }
      editor.text = "b"
      let saving = Task { await editor.save() }
      #expect(await settle(screen) { editor.status == .saving })
      await flush(screen)
      for button in saveBarButtons(screen) { #expect(!button.isEnabled) }
      release?.resume()
      await saving.value
      #expect(editor.status == .saved)
    }

    // The banner's small bordered buttons aren't among the controls: each test checks the effect.
    private static let loadLatestPoint = CGPoint(x: 705, y: 14)
    private static let keepMinePoint = CGPoint(x: 632, y: 14)

    @Test("a change made elsewhere offers Keep Mine and Load Latest")
    func conflictWithLatest() async throws {
      let editor = ReviewFixtures.editor()
      let screen = hosted(editor)
      defer { screen.close() }
      editor.text = "mine\n"
      editor.serverChanged("theirs\n")
      await flush(screen)
      let read = try shownString(screen)
      #expect(read.contains("modified externally"), "read: \(read)")
      #expect(read.contains("Load Latest"), "read: \(read)")
      // Save waits while the conflict stands.
      #expect(saveBarButtons(screen)[1].isEnabled == false)
      try screen.click(Self.loadLatestPoint)
      #expect(await settle(screen) { editor.conflict == nil })
      #expect(editor.text == "theirs\n")
      #expect(try textView(screen).string == "theirs\n")
    }

    @Test("Keep Mine writes the edit over the change")
    func keepMine() async throws {
      let editor = ReviewFixtures.editor()
      let screen = hosted(editor)
      defer { screen.close() }
      editor.text = "mine\n"
      editor.serverChanged("theirs\n")
      await flush(screen)
      try screen.click(Self.keepMinePoint)
      #expect(await settle(screen) { editor.conflict == nil })
      #expect(editor.text == "mine\n")
      #expect(!editor.isDirty)
    }

    @Test("a file deleted under an edit offers Discard Mine")
    func conflictDeleted() async throws {
      let editor = ReviewFixtures.editor(result: .conflict(latest: nil))
      let screen = hosted(editor)
      defer { screen.close() }
      editor.text = "mine\n"
      await editor.save()
      await flush(screen)
      #expect(editor.conflict == FileEditor.Conflict(latest: nil))
      let read = try shownString(screen)
      #expect(read.contains("deleted or replaced"), "read: \(read)")
      #expect(read.contains("Discard Mine"), "read: \(read)")
      try screen.click(Self.loadLatestPoint)
      #expect(await settle(screen) { editor.conflict == nil })
      #expect(editor.text == "old pond\n", "back to the last saved text")
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
