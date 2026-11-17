#if os(macOS)
  import AppKit
  import SwiftUI

  extension TranscriptTableController {
    // MARK: Keyboard

    /// How far an arrow key scrolls.
    static let keyLine: CGFloat = 40

    /// Scrolls for a key a row passed on, as the reader's own step: an arrow a line, Page Up
    /// and Down and Space (Shift-Space up) a page, Home and End to the ends.
    /// - Returns: Whether the key scrolls the transcript.
    func scrolls(for event: NSEvent) -> Bool {
      let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
      guard let key = event.charactersIgnoringModifiers?.utf16.first.map(Int.init) else {
        return false
      }
      let offset = clipView.bounds.minY
      let page = max(Self.keyLine, visibleHeight - Self.keyLine)
      let target: CGFloat
      switch (key, modifiers) {
      case (NSUpArrowFunctionKey, []): target = offset - Self.keyLine
      case (NSDownArrowFunctionKey, []): target = offset + Self.keyLine
      case (NSPageUpFunctionKey, []), (0x20, .shift): target = offset - page
      case (NSPageDownFunctionKey, []), (0x20, []): target = offset + page
      case (NSHomeFunctionKey, []):
        readerScrolled()
        moveToTop()
        return true
      case (NSEndFunctionKey, []):
        measureEnd()
        target = maximumOffset
      default: return false
      }
      // The follow rules take it as a step of the reader's wheel.
      readerScrolled()
      move(to: target)
      return true
    }

  }
#endif
