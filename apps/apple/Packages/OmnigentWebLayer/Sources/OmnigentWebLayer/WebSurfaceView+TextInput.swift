public import AppKit

/// IME state for one surface: what the input context did during the current key-down.
struct TextInputState {
  var markedText = ""
  var markedSelection = NSRange(location: 0, length: 0)
  var markedReplacement = NSRange(location: NSNotFound, length: 0)
  var hasMarkedText = false
  /// Set while `keyDown` runs the input context; callbacks are collected, then sent once.
  var handlingKeyDown = false
  var insertedText = ""
  var insertedReplacement = NSRange(location: NSNotFound, length: 0)
  var unmarkCalled = false
}

/// IME composition through `NSTextInputClient`, on the model of Chromium's own Mac view: a
/// key-down runs the input context, and what it did decides between plain key events, a
/// composition update, or committed text. See DESIGN.md, "Input".
extension WebSurfaceView: NSTextInputClient {
  func keyDownThroughInputContext(_ event: NSEvent) {
    let hadMarkedText = textInput.hasMarkedText
    textInput.handlingKeyDown = true
    textInput.insertedText = ""
    textInput.insertedReplacement = NSRange(location: NSNotFound, length: 0)
    textInput.unmarkCalled = false
    // The result is always true for a view with an input context; what matters is which
    // NSTextInputClient callbacks ran.
    _ = inputContext?.handleEvent(event)
    textInput.handlingKeyDown = false
    let state = textInput
    let renderer = webView.renderer
    if !state.hasMarkedText, !hadMarkedText {
      if state.insertedText.utf16.count <= 1 {
        renderer.forwardKeyEvent(event)  // A plain key: RawKeyDown plus Char, as without IME.
      } else {
        renderer.commitText(state.insertedText, replacementRange: state.insertedReplacement)
      }
      return
    }
    if !state.insertedText.isEmpty {
      renderer.commitText(state.insertedText, replacementRange: state.insertedReplacement)
    } else if state.hasMarkedText, !state.markedText.isEmpty {
      renderer.setComposition(
        state.markedText, selectedRange: state.markedSelection,
        replacementRange: state.markedReplacement)
    } else if hadMarkedText, !state.hasMarkedText {
      if state.unmarkCalled {
        renderer.finishComposing(keepSelection: false)
      } else {
        renderer.cancelComposition()
      }
    }
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = Self.plainText(string)
    textInput.hasMarkedText = false
    textInput.markedText = ""
    if textInput.handlingKeyDown {
      textInput.insertedText += text
      textInput.insertedReplacement = replacementRange
    } else {
      // Not from a key (emoji palette, dictation, the proof's simulated input method).
      webView.renderer.commitText(text, replacementRange: replacementRange)
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let text = Self.plainText(string)
    textInput.markedText = text
    textInput.markedSelection = selectedRange
    textInput.markedReplacement = replacementRange
    textInput.hasMarkedText = !text.isEmpty
    guard !textInput.handlingKeyDown else { return }
    if text.isEmpty {
      webView.renderer.cancelComposition()
    } else {
      webView.renderer.setComposition(
        text, selectedRange: selectedRange, replacementRange: replacementRange)
    }
  }

  func unmarkText() {
    textInput.hasMarkedText = false
    textInput.markedText = ""
    textInput.unmarkCalled = true
    if !textInput.handlingKeyDown {
      webView.renderer.finishComposing(keepSelection: false)
    }
  }

  func hasMarkedText() -> Bool {
    textInput.hasMarkedText
  }

  func markedRange() -> NSRange {
    textInput.hasMarkedText
      ? NSRange(location: 0, length: textInput.markedText.utf16.count)
      : NSRange(location: NSNotFound, length: 0)
  }

  func selectedRange() -> NSRange {
    webView.selectedRange
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    [.underlineStyle, .underlineColor, .backgroundColor]
  }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    // Only the selection is mirrored from the page; other text is not available here.
    range == webView.selectedRange ? NSAttributedString(string: webView.selectedText) : nil
  }

  func characterIndex(for point: NSPoint) -> Int {
    NSNotFound
  }

  /// Positions the candidate window under the composition, using the character rects the host
  /// reports (`ImeCompositionChanged`).
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    let rects = webView.compositionCharacterRects
    let local: CGRect
    if rects.isEmpty {
      local = CGRect(x: 0, y: bounds.height, width: 0, height: 0)
    } else {
      let index = min(max(0, range.location == NSNotFound ? 0 : range.location), rects.count - 1)
      local = rects[index]
    }
    guard let window = hostWindow else { return .zero }
    return window.convertToScreen(convert(local, to: nil))
  }

  override func doCommand(by selector: Selector) {
    // Editing commands (arrows, delete, return) reach the page as the key events `keyDown`
    // forwards when no text was inserted.
  }

  private static func plainText(_ string: Any) -> String {
    if let attributed = string as? NSAttributedString {
      return attributed.string
    }
    return string as? String ?? ""
  }
}
