// Part of TerminalSurfaceUIView; see TerminalSurfaceUIView.swift for attribution.

#if os(iOS)
  import OmnigentGhosttyKit
  import UIKit

  // UITextInput over the composing (marked) text only. Committed text goes to the terminal
  // immediately, so there is nothing else to edit or select.
  extension TerminalSurfaceUIView: UITextInput {
    var selectedTextRange: UITextRange? {
      get {
        TerminalTextRange(
          markedSelection.location, markedSelection.location + markedSelection.length)
      }
      set {
        guard let range = newValue as? TerminalTextRange else { return }
        markedSelection = NSRange(location: range.lower, length: range.upper - range.lower)
      }
    }

    var markedTextRange: UITextRange? {
      markedText.isEmpty ? nil : TerminalTextRange(0, markedText.utf16.count)
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
      self.markedText = markedText ?? ""
      markedSelection = selectedRange
      syncPreedit()
    }

    func unmarkText() {
      guard !markedText.isEmpty else { return }
      let committed = markedText
      markedText = ""
      syncPreedit()
      controller?.type(committed)
    }

    func syncPreedit() {
      guard let surface = unsafe controller?.surface else { return }
      if markedText.isEmpty {
        unsafe ghostty_surface_preedit(surface, nil, 0)
      } else {
        markedText.withCString { pointer in
          unsafe ghostty_surface_preedit(surface, pointer, UInt(markedText.utf8.count))
        }
      }
    }

    var beginningOfDocument: UITextPosition { TerminalTextPosition(0) }
    var endOfDocument: UITextPosition { TerminalTextPosition(markedText.utf16.count) }

    func text(in range: UITextRange) -> String? {
      guard let range = range as? TerminalTextRange else { return nil }
      let utf16 = Array(markedText.utf16)
      let lower = max(0, min(range.lower, utf16.count))
      let upper = max(lower, min(range.upper, utf16.count))
      return String(decoding: utf16[lower..<upper], as: UTF16.self)
    }

    func replace(_ range: UITextRange, withText text: String) {
      insertText(text)
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange?
    {
      guard let from = fromPosition as? TerminalTextPosition,
        let to = toPosition as? TerminalTextPosition
      else { return nil }
      return TerminalTextRange(min(from.offset, to.offset), max(from.offset, to.offset))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
      guard let position = position as? TerminalTextPosition else { return nil }
      let target = position.offset + offset
      return (0...markedText.utf16.count).contains(target) ? TerminalTextPosition(target) : nil
    }

    func position(
      from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int
    ) -> UITextPosition? {
      switch direction {
      case .left, .up: self.position(from: position, offset: -offset)
      default: self.position(from: position, offset: offset)
      }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
      let lhs = (position as? TerminalTextPosition)?.offset ?? 0
      let rhs = (other as? TerminalTextPosition)?.offset ?? 0
      return lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
      ((toPosition as? TerminalTextPosition)?.offset ?? 0)
        - ((from as? TerminalTextPosition)?.offset ?? 0)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection)
      -> UITextPosition?
    {
      switch direction {
      case .left, .up: range.start
      default: range.end
      }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection)
      -> UITextRange?
    {
      guard let end = self.position(from: position, in: direction, offset: 1) else { return nil }
      return textRange(from: position, to: end)
    }

    func baseWritingDirection(
      for position: UITextPosition, in direction: UITextStorageDirection
    ) -> NSWritingDirection { .leftToRight }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    /// The composition rectangle: Ghostty's cursor position, so the candidate window sits at the
    /// cursor.
    func firstRect(for range: UITextRange) -> CGRect {
      caretRect(for: range.start)
    }

    func caretRect(for position: UITextPosition) -> CGRect {
      guard let surface = unsafe controller?.surface else { return .zero }
      var originX = 0.0
      var originY = 0.0
      var width = 0.0
      var height = 0.0
      unsafe ghostty_surface_ime_point(surface, &originX, &originY, &width, &height)
      return CGRect(
        x: originX, y: originY - height, width: max(width, 1), height: max(height, 1))
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
      range.end
    }

    func characterRange(at point: CGPoint) -> UITextRange? { nil }
  }
#endif
