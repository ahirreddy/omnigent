public import AppKit
internal import OmnigentInput

/// The composer's results go to the page's renderer.
extension WebSurfaceView: TextInputSink {
  func forwardKeyEvent(_ event: NSEvent) {
    webView.renderer.forwardKeyEvent(event)
  }

  func commitText(_ text: String, replacementRange: NSRange) {
    webView.renderer.commitText(text, replacementRange: replacementRange)
  }

  func setComposition(_ text: String, selectedRange: NSRange, replacementRange: NSRange) {
    webView.renderer.setComposition(
      text, selectedRange: selectedRange, replacementRange: replacementRange)
  }

  func finishComposing(keepSelection: Bool) {
    webView.renderer.finishComposing(keepSelection: keepSelection)
  }

  func cancelComposition() {
    webView.renderer.cancelComposition()
  }
}

/// IME composition through `NSTextInputClient`; the state machine is the shared
/// `TextInputComposer`. See DESIGN.md, "Input".
extension WebSurfaceView: NSTextInputClient {
  func insertText(_ string: Any, replacementRange: NSRange) {
    textComposer.insertText(string, replacementRange: replacementRange)
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    textComposer.setMarkedText(
      string, selectedRange: selectedRange, replacementRange: replacementRange)
  }

  func unmarkText() {
    textComposer.unmarkText()
  }

  func hasMarkedText() -> Bool {
    textComposer.hasMarkedText
  }

  func markedRange() -> NSRange {
    textComposer.markedRange
  }

  func selectedRange() -> NSRange {
    webView.selectedRange
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    TextInputComposer.validAttributesForMarkedText
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
}
