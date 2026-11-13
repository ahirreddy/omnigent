#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// The texts an editor was asked to save.
  @MainActor
  private final class SaveLog {
    var texts: [String] = []
  }

  /// The editor by keyboard: selecting with Shift and the arrows, Command-S, Command-B and
  /// Command-I, and the Edit menu's Undo and Find reaching the text.
  @MainActor
  @Suite("File editor keys", .serialized)
  struct FileEditorViewKeyTests {
    private func hosted(
      _ editor: FileEditor, markdown: Bool = false, review: FileReviewContext? = nil
    ) -> OffscreenWindow<FileEditorView> {
      OffscreenWindow(
        FileEditorView(
          editor: editor, language: nil, isMarkdown: markdown, review: review, comment: { _ in }),
        width: 760, height: 360)
    }

    /// Clicks before the first character, which gives the text the keyboard with the caret there.
    private func clickStart(_ screen: OffscreenWindow<FileEditorView>) throws -> NSTextView {
      let text = try #require(screen.allViews.compactMap { $0 as? NSTextView }.first)
      let frame = text.convert(text.bounds, to: screen.host)
      try screen.click(CGPoint(x: frame.minX + 8, y: frame.minY + 16))
      try #require(screen.window.firstResponder === text)
      try #require(text.selectedRange() == NSRange(location: 0, length: 0))
      return text
    }

    private func pressShiftArrow(
      _ screen: OffscreenWindow<FileEditorView>, keyCode: UInt16, _ character: String,
      count: Int = 1
    ) throws {
      for _ in 0..<count {
        try screen.press(keyCode: keyCode, characters: character, modifiers: .shift)
      }
    }

    @Test("Shift-Down selects lines, the bar names them and Ask quotes them; Shift-Up clears it")
    func keyboardSelection() async throws {
      let spy = ReviewSpy()
      let editor = ReviewFixtures.editor(text: "one\ntwo\nthree\n")
      let screen = hosted(editor, review: ReviewFixtures.context(spy: spy))
      defer { screen.close() }
      let plain = screen.appKitButtons.count
      let text = try clickStart(screen)
      #expect(try !screen.shows("Line 1"))
      try pressShiftArrow(screen, keyCode: 125, "\u{F701}")
      #expect(text.selectedRange() == NSRange(location: 0, length: 4))
      #expect(await settle(screen) { screen.appKitButtons.count == plain + 3 })
      #expect(try screen.shows("Line 1"))
      try pressShiftArrow(screen, keyCode: 125, "\u{F701}")
      #expect(await settle(screen) { (try? screen.shows("Lines 1-2")) == true })
      // Ask About This is the last of the bar's three actions.
      try screen.click(try #require(screen.appKitButtons.last))
      #expect(spy.asked.map(\.linesTitle) == ["lines 1-2"])
      #expect(spy.asked.first?.text.hasPrefix("one\ntwo") == true)
      try pressShiftArrow(screen, keyCode: 126, "\u{F700}", count: 2)
      #expect(text.selectedRange().length == 0)
      #expect(await settle(screen) { screen.appKitButtons.count == plain })
    }

    @Test("Command-S saves what was typed, and with nothing to save it saves nothing")
    func commandS() async throws {
      let log = SaveLog()
      let write: (String, String?) async throws(WorkspaceFailure) -> FileSaveResult = { text, _ in
        await Task.yield()
        log.texts.append(text)
        return .saved
      }
      let editor = FileEditor(path: "a.txt", text: "pond\n", lineEnding: .lf, write: write)
      editor.autosaveDelay = nil
      let screen = hosted(editor)
      defer { screen.close() }
      _ = try clickStart(screen)
      try screen.pressShortcut("s", keyCode: 1)
      await flush(screen)
      #expect(log.texts.isEmpty, "a clean file has nothing to save")
      try screen.type("old ")
      #expect(await settle(screen) { editor.isDirty })
      #expect(try screen.shows("Unsaved"))
      #expect(try screen.pressShortcut("s", keyCode: 1))
      #expect(await settle(screen) { log.texts == ["old pond\n"] })
      #expect(await settle(screen) { !editor.isDirty })
      #expect(await settle(screen) { (try? screen.shows("Saved")) == true })
    }

    @Test("Command-B and Command-I mark the selection as their buttons do, and again unmark it")
    func formatShortcuts() async throws {
      let editor = ReviewFixtures.editor(path: "a.md", text: "word\n")
      let screen = hosted(editor, markdown: true)
      defer { screen.close() }
      let text = try clickStart(screen)
      try pressShiftArrow(screen, keyCode: 124, "\u{F703}", count: 4)
      #expect(text.selectedRange() == NSRange(location: 0, length: 4))
      #expect(try screen.pressShortcut("b", keyCode: 11))
      #expect(await settle(screen) { text.string == "**word**\n" }, "\(text.string)")
      #expect(await settle(screen) { editor.text == "**word**\n" })
      #expect(try screen.pressShortcut("b", keyCode: 11))
      #expect(await settle(screen) { text.string == "word\n" }, "\(text.string)")
      #expect(try screen.pressShortcut("i", keyCode: 34))
      #expect(await settle(screen) { text.string == "*word*\n" }, "\(text.string)")
      #expect(await settle(screen) { editor.text == "*word*\n" })
    }

    @Test("the Edit menu's Undo and Redo reach the text, and the editor follows both")
    func undoAndRedo() async throws {
      let log = SaveLog()
      let write: (String, String?) async throws(WorkspaceFailure) -> FileSaveResult = { text, _ in
        await Task.yield()
        log.texts.append(text)
        return .saved
      }
      let editor = FileEditor(path: "a.txt", text: "pond\n", lineEnding: .lf, write: write)
      editor.autosaveDelay = nil
      let screen = hosted(editor)
      defer { screen.close() }
      let text = try clickStart(screen)
      try screen.type("x")
      #expect(await settle(screen) { editor.text == "xpond\n" })
      #expect(screen.sendMenuCommand(Selector(("undo:"))))
      #expect(await settle(screen) { text.string == "pond\n" }, "\(text.string)")
      #expect(await settle(screen) { editor.text == "pond\n" }, "\(editor.text)")
      #expect(screen.sendMenuCommand(Selector(("redo:"))))
      #expect(await settle(screen) { text.string == "xpond\n" }, "\(text.string)")
      #expect(await settle(screen) { editor.text == "xpond\n" }, "\(editor.text)")
      #expect(screen.sendMenuCommand(Selector(("undo:"))))
      #expect(await settle(screen) { editor.text == "pond\n" }, "\(editor.text)")
      // Undone back to the saved text, Command-S has nothing to write and the edit reads clean.
      try screen.pressShortcut("s", keyCode: 1)
      #expect(await settle(screen) { !editor.isDirty })
      #expect(log.texts.isEmpty, "\(log.texts)")
    }

    @Test(
      "an undo elsewhere in the window, or one that changed nothing here, leaves the edit clean")
    func otherUndo() async throws {
      let editor = ReviewFixtures.editor(text: "pond\n")
      let screen = hosted(editor)
      defer { screen.close() }
      let text = try clickStart(screen)
      let center = NotificationCenter.default
      center.post(name: .NSUndoManagerDidUndoChange, object: UndoManager())
      center.post(name: .NSUndoManagerDidUndoChange, object: text.undoManager)
      await flush(screen)
      #expect(!editor.isDirty)
      #expect(editor.text == "pond\n")
    }

    @Test("the Edit menu's Find shows the editor's own find bar, and hiding it puts it away")
    func findBar() async throws {
      let editor = ReviewFixtures.editor(text: "old pond\nfrog\n")
      let screen = hosted(editor)
      defer { screen.close() }
      let text = try clickStart(screen)
      let scroll = try #require(text.enclosingScrollView)
      #expect(!scroll.isFindBarVisible)
      let find = #selector(NSResponder.performTextFinderAction(_:))
      #expect(screen.sendMenuCommand(find, tag: NSTextFinder.Action.showFindInterface.rawValue))
      #expect(await settle(screen) { scroll.isFindBarVisible })
      #expect(screen.sendMenuCommand(find, tag: NSTextFinder.Action.hideFindInterface.rawValue))
      #expect(await settle(screen) { !scroll.isFindBarVisible })
      #expect(editor.text == "old pond\nfrog\n", "finding edits nothing")
    }
  }
#endif
