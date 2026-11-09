import AppKit
import SwiftUI
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// Text views in windows that are never shown. Without the guard these throw, quitting the tests.
@MainActor
@Suite("Text undo guard", .serialized)
struct TextUndoGuardTests {
  private static let typed = "https://example.com"

  @MainActor @Observable final class Draft {
    var text = ""
  }

  private struct Editor: View {
    @Bindable var draft: Draft
    var body: some View { TextEditor(text: $draft.text).frame(width: 300, height: 200) }
  }

  private final class Marker: NSObject {
    var undone = false
    @objc func mark(_ argument: Any?) { undone = true }
  }

  /// A window with `content`, focused on the text view inside it.
  private func focusedTextView(in content: NSView) async throws -> (NSWindow, NSTextView) {
    TextUndoGuard.install()
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    try await settle()
    content.layoutSubtreeIfNeeded()
    try await settle()
    let textView = try #require(find(in: content))
    #expect(window.makeFirstResponder(textView))
    return (window, textView)
  }

  private func find(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    return view.subviews.lazy.compactMap { find(in: $0) }.first
  }

  /// Lets SwiftUI update and main-queue work run.
  private func settle() async throws {
    try await Task.sleep(for: .milliseconds(150))
  }

  private func type(_ text: String, into textView: NSTextView) async throws {
    textView.insertText(text, replacementRange: textView.selectedRange())
    textView.breakUndoCoalescing()
    try await settle()
  }

  @Test func undoAfterATextEditorIsClearedLeavesItEmpty() async throws {
    let draft = Draft()
    let (window, textView) = try await focusedTextView(
      in: NSHostingView(rootView: Editor(draft: draft)))
    defer { window.close() }
    try await type(Self.typed, into: textView)
    #expect(draft.text == Self.typed)

    draft.text = ""
    try await settle()
    window.undoManager?.undo()
    try await settle()
    #expect(textView.string.isEmpty)
    #expect(draft.text.isEmpty)
    #expect(window.firstResponder === textView)
  }

  @Test func otherUndoInTheWindowSurvives() async throws {
    let draft = Draft()
    let (window, textView) = try await focusedTextView(
      in: NSHostingView(rootView: Editor(draft: draft)))
    defer { window.close() }
    let marker = Marker()
    window.undoManager?.registerUndo(
      withTarget: marker, selector: #selector(Marker.mark(_:)), object: nil)
    try await settle()
    try await type(Self.typed, into: textView)

    draft.text = ""
    try await settle()
    window.undoManager?.undo()
    #expect(marker.undone)
    #expect(textView.string.isEmpty)
  }

  @Test func typingUndoesAndRedoes() async throws {
    let draft = Draft()
    let (window, textView) = try await focusedTextView(
      in: NSHostingView(rootView: Editor(draft: draft)))
    defer { window.close() }
    try await type(Self.typed, into: textView)

    window.undoManager?.undo()
    try await settle()
    #expect(textView.string.isEmpty)
    #expect(window.undoManager?.canRedo == true)

    window.undoManager?.redo()
    try await settle()
    #expect(textView.string == Self.typed)

    window.undoManager?.undo()
    try await settle()
    #expect(textView.string.isEmpty)
  }

  @Test func typingAfterAClearUndoesOnlyThatTyping() async throws {
    let draft = Draft()
    let (window, textView) = try await focusedTextView(
      in: NSHostingView(rootView: Editor(draft: draft)))
    defer { window.close() }
    try await type(Self.typed, into: textView)
    draft.text = ""
    try await settle()

    try await type("next", into: textView)
    #expect(draft.text == "next")
    #expect(window.undoManager?.canUndo == true)
    window.undoManager?.undo()
    try await settle()
    #expect(textView.string.isEmpty)
  }

  @Test func aDraftReplacedByALongerOneUndoesNothing() async throws {
    let draft = Draft()
    let (window, textView) = try await focusedTextView(
      in: NSHostingView(rootView: Editor(draft: draft)))
    defer { window.close() }
    try await type(Self.typed, into: textView)
    draft.text = "another session's much longer draft"
    try await settle()

    window.undoManager?.undo()
    try await settle()
    #expect(textView.string == "another session's much longer draft")
  }

  /// How the file editor loads a file over what was typed.
  @Test func anAppKitTextReplacedInItsStorageUndoesNothing() async throws {
    let scrollView = NSTextView.scrollableTextView()
    let (window, textView) = try await focusedTextView(in: scrollView)
    defer { window.close() }
    textView.allowsUndo = true
    try await type(Self.typed, into: textView)
    #expect(window.undoManager?.canUndo == true)

    let storage = try #require(unsafe textView.textStorage)
    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
    try await settle()
    window.undoManager?.undo()
    #expect(textView.string.isEmpty)
  }

  /// Coloring changes attributes only; the file editor does it after every edit.
  @Test func attributeChangesKeepTheUndo() async throws {
    let scrollView = NSTextView.scrollableTextView()
    let (window, textView) = try await focusedTextView(in: scrollView)
    defer { window.close() }
    textView.allowsUndo = true
    try await type(Self.typed, into: textView)

    let storage = try #require(unsafe textView.textStorage)
    storage.addAttribute(
      .foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: storage.length))
    try await settle()
    #expect(window.undoManager?.canUndo == true)
    window.undoManager?.undo()
    #expect(textView.string.isEmpty)
  }
}
