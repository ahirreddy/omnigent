#if os(macOS)
  import AppKit

  /// A message action's button in a text cell, as ``MessageActionRow`` draws one: it tells its
  /// row when it takes or gives up the keyboard, so the row stays shown while it has it.
  final class TranscriptMessageActionButton: NSButton {
    /// Told once the button has taken or given up the keyboard.
    var focusChanged: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
      let became = super.becomeFirstResponder()
      if became { focusChanged?() }
      return became
    }

    override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned { focusChanged?() }
      return resigned
    }
  }
#endif
