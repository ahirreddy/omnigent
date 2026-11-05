#if os(macOS)
  import AppKit
  import Foundation
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  // Text views count in UTF-16 offsets, as `NSString` does.
  // swiftlint:disable legacy_objc_type

  @Suite("Code editor typing")
  struct CodeEditorTypingTests {
    /// A 2,000-line Swift file.
    private static let longFile =
      (1...2_000).map { line in
        "  let value\(line) = compute(\"row \(line)\", count: \(line)) // step \(line)"
      }.joined(separator: "\n") + "\n"

    // swiftlint:disable:next large_tuple
    private func editorView(_ text: String) -> (
      FileEditor, CodeEditorTextView.Coordinator, NSTextView
    ) {
      let editor = FileEditor(path: "Long.swift", text: text, lineEnding: .lf) { _, _ in .saved }
      editor.autosaveDelay = nil
      let coordinator = CodeEditorTextView.Coordinator(
        editor: editor, language: .swift, scheme: .light, onSelection: { _ in })
      let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
      textView.isRichText = false
      textView.delegate = coordinator
      return (editor, coordinator, textView)
    }

    /// Types `count` characters at the selection; the time per keystroke.
    private static func type(_ count: Int, into textView: NSTextView) -> Duration {
      let start = ContinuousClock.now
      for _ in 0..<count {
        textView.insertText("x", replacementRange: textView.selectedRange())
      }
      return (ContinuousClock.now - start) / count
    }

    private func color(_ storage: NSTextStorage, at offset: Int) -> NSColor? {
      unsafe storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
    }

    @Test("a keystroke in a 2,000-line file colors one line and neither copies nor compares it")
    func keystrokeCost() async throws {
      let (editor, coordinator, textView) = editorView(Self.longFile)
      unsafe coordinator.load(textView.textStorage)
      let storage = try #require(unsafe textView.textStorage)
      await coordinator.highlighter.backgroundScanned()
      let keyword = NSColor(WorkspaceTheme.tokenColor(.keyword, .light))
      let lastLine = (Self.longFile as NSString).range(of: "  let value2000").location + 2
      #expect(color(storage, at: lastLine) == keyword, "the whole file is colored")

      // Type 200 characters in the middle of the file.
      let middle = NSMaxRange((Self.longFile as NSString).range(of: "value1000 "))
      textView.setSelectedRange(NSRange(location: middle, length: 0))
      let keystrokes = 200
      let perKeystroke = Self.type(keystrokes, into: textView)
      // The same typing in a plain text view, for what highlighting and the editor add.
      let plain = NSTextView(frame: textView.frame)
      plain.string = Self.longFile
      plain.setSelectedRange(NSRange(location: middle, length: 0))
      let plainPerKeystroke = Self.type(keystrokes, into: plain)
      print("2,000-line file: \(perKeystroke) per keystroke; plain text view \(plainPerKeystroke)")
      #expect(editor.isDirty)
      #expect(editor.text.contains("value1000 " + String(repeating: "x", count: keystrokes)))
      // Idle, the editor adds about 1 ms; copying or comparing the file would add tens. The
      // margin holds on a loaded machine, where both views slow down.
      #expect(
        perKeystroke < plainPerKeystroke * 3 + .milliseconds(5),
        "highlighting and the editor add little to a keystroke")
      let typedLine = (storage.string as NSString).range(of: "  let value1000").location + 2
      #expect(color(storage, at: typedLine) == keyword, "the typed line is colored again")
    }

    @Test("typing back to the saved text saves nothing")
    func typedBack() async {
      let (editor, coordinator, textView) = editorView("let a = 1\n")
      unsafe coordinator.load(textView.textStorage)
      textView.setSelectedRange(NSRange(location: 9, length: 0))
      textView.insertText("2", replacementRange: textView.selectedRange())
      #expect(editor.isDirty)
      textView.insertText("", replacementRange: NSRange(location: 9, length: 1))
      await editor.save()
      #expect(!editor.isDirty)
      #expect(editor.status == .clean)
    }

    @Test("a replaced text reloads the view; a theme change recolors it")
    func sync() async throws {
      let (editor, coordinator, textView) = editorView("let a = 1\n")
      unsafe coordinator.load(textView.textStorage)
      let storage = try #require(unsafe textView.textStorage)
      textView.setSelectedRange(NSRange(location: 9, length: 0))
      textView.insertText("2", replacementRange: textView.selectedRange())
      #expect(editor.text == "let a = 12\n")
      editor.revert()
      coordinator.sync(storage, editor: editor, scheme: .light)
      #expect(storage.string == "let a = 1\n")
      coordinator.sync(storage, editor: editor, scheme: .dark)
      await coordinator.highlighter.backgroundScanned()
      #expect(color(storage, at: 0) == NSColor(WorkspaceTheme.tokenColor(.keyword, .dark)))
    }
  }
// swiftlint:enable legacy_objc_type
#endif
