#if os(iOS)
  import Foundation
  import OmnigentViewTesting
  import Testing
  import UIKit

  @testable import OmnigentTerminalUI

  @Suite("Terminal on iOS: the software keyboard and its accessory row", .serialized)
  struct TerminalSoftwareKeyboardTests {
    @Test("typed text, Return and Delete reach the program as a terminal expects them")
    func typing() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      #expect(surface.view.hasText)
      surface.view.insertText("ls")
      #expect(await surface.receives("ls"))
      surface.view.insertText("\n")
      #expect(await surface.receives("ls\r"))
      surface.view.deleteBackward()
      #expect(await surface.receives("ls\r\u{7f}"))
      // Replacing a range is typing: there is no document to replace in.
      surface.view.replace(TerminalTextRange(0, 0), withText: "pwd")
      #expect(await surface.receives("ls\r\u{7f}pwd"))
    }

    @Test("the keyboard is plain: no corrections, no smart punctuation, the accessory row above")
    func traits() throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      let view = surface.view
      #expect(view.inputAccessoryView === view.accessoryBar)
      #expect(view.autocorrectionType == .no)
      #expect(view.autocapitalizationType == .none)
      #expect(view.spellCheckingType == .no)
      #expect(view.smartQuotesType == .no)
      #expect(view.smartDashesType == .no)
      #expect(view.smartInsertDeleteType == .no)
      #expect(view.inlinePredictionType == .no)
      #expect(view.keyboardType == .asciiCapable)
      #expect(view.returnKeyType == .default)
      #expect(view.markedTextStyle == nil)
      #expect(view.inputDelegate == nil)
      #expect(view.tokenizer is UITextInputStringTokenizer)
    }

    @Test("ctrl on the accessory row is sticky for one key, then lets go")
    func stickyControl() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      let control = try #require(surface.accessoryButton("Control"))
      #expect(control.accessibilityValue == "Off")
      #expect(surface.pressAccessory("Control"))
      #expect(control.accessibilityValue == "On")
      surface.view.insertText("c")
      #expect(await surface.receives("\u{3}"))
      #expect(control.accessibilityValue == "Off")
      surface.view.insertText("c")
      #expect(await surface.receives("\u{3}c"))
      // Pressed twice, it is off again.
      #expect(surface.pressAccessory("Control"))
      #expect(surface.pressAccessory("Control"))
      #expect(control.accessibilityValue == "Off")
      #expect(surface.view.accessoryBar.takeModifiers().isEmpty)
    }

    @Test("alt and ctrl apply to the accessory row's own keys, and to Delete")
    func stickyModifiersOnAccessoryKeys() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      let option = try #require(surface.accessoryButton("Option"))
      #expect(surface.pressAccessory("Option"))
      #expect(option.accessibilityValue == "On")
      #expect(surface.pressAccessory("Left"))
      // Option changes what Left sends; the exact sequence is Ghostty's to choose.
      #expect(await eventually { !surface.connection.received.isEmpty })
      let optionLeft = surface.sent
      #expect(optionLeft.hasPrefix("\u{1b}"))
      #expect(optionLeft != "\u{1b}[D")
      #expect(option.accessibilityValue == "Off")

      #expect(surface.pressAccessory("Control"))
      #expect(surface.pressAccessory("Option"))
      #expect(surface.view.accessoryBar.takeModifiers() == [.control, .option])
      #expect(surface.view.accessoryBar.takeModifiers().isEmpty)

      // The row has no letters, but its text keys take ctrl the way typed letters do.
      #expect(surface.pressAccessory("Control"))
      surface.view.accessoryBar.onKey?(.text("d"))
      #expect(await surface.receives(optionLeft + "\u{4}"))
      #expect(surface.pressAccessory("Control"))
      #expect(surface.pressAccessory("-"))
      #expect(await surface.receives(optionLeft + "\u{4}-"))
    }

    @Test(
      "each accessory key sends its key",
      arguments: [
        ("Escape", "\u{1b}"), ("Tab", "\t"), ("Left", "\u{1b}[D"), ("Down", "\u{1b}[B"),
        ("Up", "\u{1b}[A"), ("Right", "\u{1b}[C"), ("~", "~"), ("|", "|"), ("/", "/"), ("-", "-"),
        ("`", "`"),
      ])
    func accessoryKeys(label: String, bytes: String) async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      #expect(surface.pressAccessory(label))
      #expect(await surface.receives(bytes), "\(label) sent \(surface.connection.received)")
    }

    // A test process may not read the pasteboard's contents, so a paste here finds no text;
    // TerminalClipboardTests pastes text through the same controller on the Mac.
    @Test(
      "the row's Paste with nothing to paste types nothing, and its last key hides the keyboard")
    func pasteAndDismiss() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      UIPasteboard.general.items = []
      #expect(surface.pressAccessory("Paste"))
      try await surface.programPrints("after the paste")
      #expect(await eventually { surface.controller.visibleText().contains("after the paste") })
      #expect(surface.connection.received.isEmpty)

      #expect(surface.view.becomeFirstResponder())
      #expect(surface.pressAccessory("Hide keyboard"))
      #expect(!surface.view.isFirstResponder)
      #expect(!surface.pressAccessory("No such key"))
    }

    @Test("only a single ASCII letter has a key code for a Control chord")
    func letterKeyCodes() {
      #expect(TerminalSurfaceUIView.letterKeyCode("a") == HIDKeyCodes.macKeyCode[0x04])
      #expect(TerminalSurfaceUIView.letterKeyCode("Z") == HIDKeyCodes.macKeyCode[0x1D])
      #expect(TerminalSurfaceUIView.letterKeyCode("c") == 0x08)
      for text in ["", "ab", "1", "-", "é", "\n"] {
        #expect(TerminalSurfaceUIView.letterKeyCode(text) == nil, "\(text)")
      }
    }

    @Test("a view whose surface is gone takes input and sends nothing")
    func withoutASurface() {
      let view = TerminalSurfaceUIView(frame: CGRect(x: 0, y: 0, width: 100, height: 50))
      view.insertText("a")
      view.deleteBackward()
      view.accessoryBar.onKey?(.text("a"))
      view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
      #expect(view.markedText == "か")
      view.unmarkText()
      #expect(view.markedText.isEmpty)
      #expect(view.caretRect(for: TerminalTextPosition(0)) == .zero)
      view.scroll(deltaX: 0, deltaY: 10, momentum: false)
      view.tapped(ScriptedTap())
      view.longPressed(ScriptedLongPress())
      view.pressesBegan(ScriptedKey("c", .keyboardC, .control).pressed, with: nil)
      #expect(view.heldKeys.isEmpty)
      #expect(!view.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil))
      view.copy(nil)
      view.paste(nil)
      view.selectAll(nil)
      #expect(view.requestRender())
      view.stopRendering()
      #expect(view.displayLink == nil)
    }
  }

  @Suite("Terminal on iOS: composing text", .serialized)
  struct TerminalMarkedTextTests {
    @Test("composing text is held back until committed, then typed")
    func composition() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      let view = surface.view
      #expect(view.markedTextRange == nil)
      view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0))
      #expect(view.markedText == "にほ")
      let marked = try #require(view.markedTextRange as? TerminalTextRange)
      #expect(marked.lower == 0)
      #expect(marked.upper == 2)
      #expect(!marked.isEmpty)
      let selected = try #require(view.selectedTextRange as? TerminalTextRange)
      #expect(selected.lower == 2)
      #expect(selected.isEmpty)
      #expect(view.text(in: TerminalTextRange(0, 1)) == "に")
      #expect(view.text(in: TerminalTextRange(-4, 99)) == "にほ")
      #expect(view.text(in: UITextRange()) == nil)
      // A hardware key during composition belongs to the input method.
      view.pressesBegan(ScriptedKey("c", .keyboardC, .control).pressed, with: nil)
      #expect(view.heldKeys.isEmpty)
      try await Task.sleep(for: .milliseconds(80))
      #expect(surface.connection.received.isEmpty)

      view.unmarkText()
      #expect(view.markedText.isEmpty)
      #expect(view.markedTextRange == nil)
      #expect(await surface.receives("にほ"))
      view.unmarkText()
      view.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
      try await Task.sleep(for: .milliseconds(80))
      #expect(surface.sent == "にほ")
    }

    @Test("the selection inside composing text follows what the input method sets")
    func selection() throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      let view = surface.view
      view.setMarkedText("abcd", selectedRange: NSRange(location: 1, length: 2))
      view.selectedTextRange = TerminalTextRange(0, 3)
      #expect(view.markedSelection == NSRange(location: 0, length: 3))
      // A range that is not the terminal's is ignored.
      view.selectedTextRange = UITextRange()
      view.selectedTextRange = nil
      #expect(view.markedSelection == NSRange(location: 0, length: 3))
    }

    @Test("positions and ranges count UTF-16 units of the composing text")
    func positions() throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      let view = surface.view
      view.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0))
      let start = view.beginningOfDocument
      let end = view.endOfDocument
      #expect((end as? TerminalTextPosition)?.offset == 3)
      #expect(view.offset(from: start, to: end) == 3)
      #expect(view.offset(from: UITextPosition(), to: UITextPosition()) == 0)
      #expect(view.compare(start, to: end) == .orderedAscending)
      #expect(view.compare(end, to: start) == .orderedDescending)
      #expect(view.compare(end, to: end) == .orderedSame)

      let middle = try #require(view.position(from: start, offset: 2) as? TerminalTextPosition)
      #expect(middle.offset == 2)
      #expect(view.position(from: start, offset: 4) == nil)
      #expect(view.position(from: start, offset: -1) == nil)
      #expect(view.position(from: UITextPosition(), offset: 0) == nil)
      let left = view.position(from: middle, in: .left, offset: 1) as? TerminalTextPosition
      #expect(left?.offset == 1)
      let above = view.position(from: middle, in: .up, offset: 2) as? TerminalTextPosition
      #expect(above?.offset == 0)
      let right = view.position(from: middle, in: .right, offset: 1) as? TerminalTextPosition
      #expect(right?.offset == 3)

      let range = try #require(view.textRange(from: end, to: middle) as? TerminalTextRange)
      #expect(range.lower == 2)
      #expect(range.upper == 3)
      #expect((range.start as? TerminalTextPosition)?.offset == 2)
      #expect((range.end as? TerminalTextPosition)?.offset == 3)
      #expect(view.textRange(from: UITextPosition(), to: end) == nil)
      #expect(view.textRange(from: start, to: UITextPosition()) == nil)
      let far = view.position(within: range, farthestIn: .left) as? TerminalTextPosition
      #expect(far?.offset == 2)
      let near = view.position(within: range, farthestIn: .down) as? TerminalTextPosition
      #expect(near?.offset == 3)
      let extended = view.characterRange(byExtending: middle, in: .right) as? TerminalTextRange
      #expect(extended?.lower == 2)
      #expect(extended?.upper == 3)
      #expect(view.characterRange(byExtending: end, in: .right) == nil)
    }

    @Test("the candidate window sits at the cursor, and there is nothing else to hit-test")
    func geometry() async throws {
      let surface = try TouchSurface()
      defer { surface.close() }
      #expect(await surface.ready())
      let view = surface.view
      view.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0))
      let caret = view.caretRect(for: view.endOfDocument)
      #expect(caret.width >= 1)
      #expect(caret.height >= 1)
      #expect(view.bounds.insetBy(dx: -1, dy: -1).intersects(caret))
      #expect(view.firstRect(for: TerminalTextRange(0, 1)) == caret)
      #expect(view.selectionRects(for: TerminalTextRange(0, 1)).isEmpty)
      let closest = view.closestPosition(to: CGPoint(x: 5, y: 5)) as? TerminalTextPosition
      #expect(closest?.offset == 1)
      let within = view.closestPosition(to: .zero, within: TerminalTextRange(0, 1))
      #expect((within as? TerminalTextPosition)?.offset == 1)
      #expect(view.characterRange(at: .zero) == nil)
      #expect(view.baseWritingDirection(for: view.endOfDocument, in: .forward) == .leftToRight)
      view.setBaseWritingDirection(.rightToLeft, for: TerminalTextRange(0, 1))
      #expect(view.baseWritingDirection(for: view.endOfDocument, in: .forward) == .leftToRight)
    }
  }
#endif
