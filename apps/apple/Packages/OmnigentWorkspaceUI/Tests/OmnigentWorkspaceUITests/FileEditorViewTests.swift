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

    /// Keep Mine and its neighbor, the banner's buttons on the first row.
    private func bannerButtons<Content: View>(_ screen: OffscreenWindow<Content>) -> [CGRect] {
      screen.controlFrames.filter { $0.maxY < 30 }
    }

    private func clickBanner<Content: View>(_ screen: OffscreenWindow<Content>, _ index: Int) throws
    {
      let buttons = bannerButtons(screen)
      try #require(buttons.count == 2, "\(buttons)")
      try screen.click(CGPoint(x: buttons[index].midX, y: buttons[index].midY))
    }

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
      try clickBanner(screen, 1)
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
      try clickBanner(screen, 0)
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
      try clickBanner(screen, 1)
      #expect(await settle(screen) { editor.conflict == nil })
      #expect(editor.text == "old pond\n", "back to the last saved text")
    }
  }
#endif
