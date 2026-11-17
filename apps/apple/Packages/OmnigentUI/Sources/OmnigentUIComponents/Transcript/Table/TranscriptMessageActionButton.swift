#if os(macOS)
  import AppKit
  import QuartzCore

  /// A message action's button in a text cell, as ``MessageActionRow`` draws one: an enabled
  /// one under the pointer takes the hover highlight SwiftUI's `hoverHighlight()` gives, and it
  /// tells its row when it takes or gives up the keyboard, so the row stays shown while it has
  /// it.
  final class TranscriptMessageActionButton: NSButton {
    /// Told once the button has taken or given up the keyboard.
    var focusChanged: (() -> Void)?
    /// The highlight's color; `nil` shows none.
    var hoverColor: NSColor?
    private var hoverArea: NSTrackingArea?
    private(set) var isHovered = false

    /// How long the highlight fades in or out, as SwiftUI's feedback animation.
    static let hoverFade: CFTimeInterval = 0.16

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

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      // One area that follows the visible rect, so scrolling rebuilds nothing.
      guard hoverArea == nil else { return }
      let area = NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
        owner: self)
      addTrackingArea(area)
      hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
      super.mouseEntered(with: event)
      setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
      super.mouseExited(with: event)
      setHovered(false)
    }

    /// Shows the highlight while the pointer is over an enabled button, fading as SwiftUI's
    /// does unless motion is off or reduced.
    func setHovered(_ hovered: Bool) {
      isHovered = hovered
      wantsLayer = true
      guard let layer else { return }
      layer.cornerRadius = Theme.Radius.small
      layer.cornerCurve = .continuous
      let shown = hovered && isEnabled ? hoverColor : nil
      let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      CATransaction.begin()
      CATransaction.setDisableActions(!Theme.Motion.isEnabled || reduced)
      CATransaction.setAnimationDuration(Self.hoverFade)
      CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
      layer.backgroundColor = (shown ?? .clear).cgColor
      CATransaction.commit()
    }
  }
#endif
