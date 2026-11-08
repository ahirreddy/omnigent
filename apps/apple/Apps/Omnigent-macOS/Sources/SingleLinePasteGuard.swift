import AppKit
import ObjectiveC

/// A paste into a single-line field (a search field, a rename field) keeps its line breaks, and
/// AppKit's click handling on such text slows with the square of its lines: a double-click on a
/// few thousand pasted lines stalls the app for many seconds. One very long line of
/// right-to-left text crashes CoreText instead. The guard joins the pasted lines with spaces, as a
/// browser's text input does, and keeps the field under ``maximumLength``.
///
/// The replacement is nonisolated for the same reason as ``ToolbarSwapGuard``'s.
enum SingleLinePasteGuard {
  nonisolated(unsafe) private static var isInstalled = false

  /// Guards every single-line field's paste and drop from now on.
  /// - Returns: Whether AppKit had the method to guard.
  @MainActor @discardableResult
  static func install() -> Bool {
    guard unsafe !isInstalled else { return true }
    guard
      let original = unsafe class_getInstanceMethod(
        NSTextView.self, #selector(NSTextView.readSelection(from:type:))),
      let replacement = unsafe class_getInstanceMethod(
        NSTextView.self, #selector(NSTextView.singleLineGuardReadSelection(from:type:)))
    else { return false }
    unsafe method_exchangeImplementations(original, replacement)
    unsafe isInstalled = true
    return true
  }

  /// The most UTF-16 units a paste leaves in a single-line field, well under the 9,000 or so
  /// past which CoreText crashes laying out one line of mixed-direction text.
  nonisolated static let maximumLength = 4000

  /// `text` on one line: each run of line breaks becomes a space, and leading and trailing
  /// ones are dropped.
  nonisolated static func joined(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).joined(separator: " ")
  }

  /// What a paste of `text` inserts into a single-line field with `room` UTF-16 units left:
  /// its lines joined, cut after the last whole character that fits.
  nonisolated static func pasted(_ text: String, room: Int) -> String {
    var result = ""
    var length = 0
    for character in joined(text) {
      length += character.utf16.count
      guard length <= room else { break }
      result.append(character)
    }
    return result
  }
}

extension NSTextView {
  /// Once installed this is `readSelectionFromPasteboard:type:`; calling it calls AppKit's. It
  /// reads the view through Objective-C messages, which carry no main-actor check.
  @objc nonisolated fileprivate func singleLineGuardReadSelection(
    from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType
  ) -> Bool {
    guard value(forKey: "fieldEditor") as? Bool == true,
      let field = value(forKey: "delegate") as? NSTextField, Self.isSingleLine(field),
      let text = pasteboard.string(forType: .string),
      let current = value(forKey: "string") as? String,
      let selection = (value(forKey: "selectedRange") as? NSValue)?.rangeValue
    else { return singleLineGuardReadSelection(from: pasteboard, type: type) }
    let room = max(0, SingleLinePasteGuard.maximumLength - (current.utf16.count - selection.length))
    guard text.contains(where: \.isNewline) || text.utf16.count > room else {
      return singleLineGuardReadSelection(from: pasteboard, type: type)
    }
    // `insertText:` replaces the selection, as a paste does, with undo.
    let pasted = SingleLinePasteGuard.pasted(text, room: room)
    _ = unsafe perform(#selector(NSResponder.insertText(_:)), with: pasted)
    return true
  }

  /// Whether `field` keeps its text on one line.
  nonisolated private static func isSingleLine(_ field: NSTextField) -> Bool {
    guard let cell = field.value(forKey: "cell") as? NSObject else { return false }
    return cell.value(forKey: "usesSingleLineMode") as? Bool == true
      || cell.value(forKey: "scrollable") as? Bool == true
  }
}
