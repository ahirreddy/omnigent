// Part of TerminalSurfaceNSView; adapted from Ghostty's macOS app
// (`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`), MIT License, Copyright (c)
// 2024 Mitchell Hashimoto, Ghostty contributors. See THIRD_PARTY_NOTICES.md.

#if os(macOS)
  import AppKit
  import OmnigentGhosttyKit

  /// IME support: marked text becomes Ghostty preedit; committed text is typed.
  extension TerminalSurfaceNSView: NSTextInputClient {

    func insertText(_ string: Any, replacementRange: NSRange) {
      let text: String
      if let attributed = string as? NSAttributedString {
        text = attributed.string
      } else if let plain = string as? String {
        text = plain
      } else {
        return
      }
      unmarkText()
      if interpretingKeyDown {
        keyText.append(text)
      } else {
        controller?.type(text)
      }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
      if let attributed = string as? NSAttributedString {
        markedText = NSMutableAttributedString(attributedString: attributed)
      } else if let plain = string as? String {
        markedText = NSMutableAttributedString(string: plain)
      }
      if !interpretingKeyDown { syncPreedit(clearIfNeeded: true) }
    }

    func unmarkText() {
      guard markedText.length > 0 else { return }
      markedText.mutableString.setString("")
      syncPreedit(clearIfNeeded: true)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
      markedText.length > 0
        ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func attributedSubstring(
      forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
      guard let surface = unsafe controller?.surface, let window = unsafe window else {
        return .zero
      }
      var originX = 0.0
      var originY = 0.0
      var width = 0.0
      var height = 0.0
      unsafe ghostty_surface_ime_point(surface, &originX, &originY, &width, &height)
      // Ghostty reports a top-left origin in view points; AppKit wants screen coordinates.
      let viewRect = NSRect(
        x: originX, y: frame.height - originY, width: width, height: max(height, 1))
      return window.convertToScreen(convert(viewRect, to: nil))
    }
  }
#endif
