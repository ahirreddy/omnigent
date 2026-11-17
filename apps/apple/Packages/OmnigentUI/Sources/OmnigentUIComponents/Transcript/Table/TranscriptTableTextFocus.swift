#if os(macOS)
  import AppKit

  /// What the system's assistive settings say, read as a text cell shows its actions; a test
  /// gives its own.
  @MainActor
  struct TranscriptTableAssistive {
    /// Keyboard navigation reaches every control: a message takes focus, as a SwiftUI one made
    /// focusable for activation does.
    var keyboardNavigates: @MainActor () -> Bool = {
      NSApplication.shared.isFullKeyboardAccessEnabled
    }
    /// VoiceOver is on: every message shows its actions, as a SwiftUI row's do.
    var voiceOverIsOn: @MainActor () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
  }

  /// A text cell's keyboard focus, as a SwiftUI message row's: with keyboard navigation on, the
  /// message takes focus, which reveals its actions and rings it, and they stay shown while
  /// focus moves on to one of them.
  extension TranscriptTableTextCell {
    static var assistive = TranscriptTableAssistive()

    override var acceptsFirstResponder: Bool {
      message != nil && Self.assistive.keyboardNavigates()
    }

    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override func becomeFirstResponder() -> Bool {
      let became = super.becomeFirstResponder()
      if became { refreshActions() }
      return became
    }

    override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      // After the change settles, so the actions see whether focus went to one of them.
      if resigned { focusMoved() }
      return resigned
    }

    /// The actions show again or hide once focus has moved, here or within them.
    func focusMoved() {
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated { self?.refreshActions() }
      }
    }

    /// Whether the message or one of its actions has the keyboard.
    var hasKeyboardFocus: Bool {
      guard let responder = unsafe window?.firstResponder as? NSView else { return false }
      if responder === self { return true }
      guard let actionsView else { return false }
      return responder.isDescendant(of: actionsView)
    }

    override var focusRingMaskBounds: NSRect { contentFrame }

    override func drawFocusRingMask() {
      NSBezierPath(
        roundedRect: contentFrame, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small
      ).fill()
    }
  }
#endif
