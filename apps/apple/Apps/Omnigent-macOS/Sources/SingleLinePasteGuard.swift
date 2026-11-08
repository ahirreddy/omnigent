import AppKit
import ObjectiveC

/// A paste of many lines into a single-line field (a search field, a rename field) keeps its
/// line breaks, and AppKit's click handling on such text slows with the square of its lines: a
/// double-click on a few thousand pasted lines stalls the app for many seconds. The guard joins
/// the pasted lines with spaces, as a browser's text input does.
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

  /// `text` on one line: each run of line breaks becomes a space, and leading and trailing
  /// ones are dropped.
  nonisolated static func joined(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).joined(separator: " ")
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
      let text = pasteboard.string(forType: .string), text.contains(where: \.isNewline)
    else { return singleLineGuardReadSelection(from: pasteboard, type: type) }
    // `insertText:` replaces the selection, as a paste does, with undo.
    _ = unsafe perform(
      #selector(NSResponder.insertText(_:)), with: SingleLinePasteGuard.joined(text))
    return true
  }

  /// Whether `field` keeps its text on one line.
  nonisolated private static func isSingleLine(_ field: NSTextField) -> Bool {
    guard let cell = field.value(forKey: "cell") as? NSObject else { return false }
    return cell.value(forKey: "usesSingleLineMode") as? Bool == true
      || cell.value(forKey: "scrollable") as? Bool == true
  }
}
