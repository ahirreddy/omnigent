// Part of TerminalSurfaceUIView; see TerminalSurfaceUIView.swift for attribution.

#if os(iOS)
  import OmnigentGhosttyKit
  import UIKit

  /// Touch: focus, scrolling through scrollback, selection and the edit menu.
  extension TerminalSurfaceUIView: UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {

    @objc func tapped(_ recognizer: UITapGestureRecognizer) {
      if !isFirstResponder { _ = becomeFirstResponder() }
      guard let surface = unsafe controller?.surface else { return }
      let hasSelection = unsafe ghostty_surface_has_selection(surface)
      if selecting || hasSelection {
        unsafe ghostty_surface_clear_selection(surface)
        selecting = false
        return
      }
      // A program that tracks the mouse (a TUI's menus) gets the tap as a click.
      if unsafe ghostty_surface_mouse_captured(surface) {
        let point = recognizer.location(in: self)
        unsafe ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
        unsafe ghostty_surface_mouse_button(
          surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        unsafe ghostty_surface_mouse_button(
          surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
      }
    }

    @objc func panned(_ recognizer: UIPanGestureRecognizer) {
      switch recognizer.state {
      case .began:
        stopMomentum()
        lastPan = .zero
      case .changed:
        let translation = recognizer.translation(in: self)
        scroll(
          deltaX: translation.x - lastPan.x, deltaY: translation.y - lastPan.y, momentum: false)
        lastPan = translation
      case .ended:
        momentumVelocity = recognizer.velocity(in: self)
        startMomentum()
      default:
        break
      }
    }

    /// Scrolls by touch deltas in points: scrollback normally, or wheel reports when the
    /// program tracks the mouse.
    func scroll(deltaX: CGFloat, deltaY: CGFloat, momentum: Bool) {
      guard let surface = unsafe controller?.surface else { return }
      // Precise (pixel) scrolling, with the momentum phase set while coasting.
      var mods: Int32 = 1
      if momentum { mods |= Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue) << 1 }
      unsafe ghostty_surface_mouse_scroll(surface, Double(deltaX), Double(deltaY), mods)
    }

    func startMomentum() {
      stopMomentum()
      guard abs(momentumVelocity.y) > 60 else { return }
      let link = CADisplayLink(target: self, selector: #selector(momentumStep(_:)))
      link.add(to: .main, forMode: .common)
      momentum = link
    }

    func stopMomentum() {
      momentum?.invalidate()
      momentum = nil
    }

    @objc func momentumStep(_ link: CADisplayLink) {
      let interval = link.targetTimestamp - link.timestamp
      momentumVelocity.y *= 0.94
      guard abs(momentumVelocity.y) > 20 else {
        stopMomentum()
        return
      }
      scroll(deltaX: 0, deltaY: momentumVelocity.y * CGFloat(interval), momentum: true)
    }

    /// Long press selects (Shift forces selection even when a TUI tracks the mouse), drag
    /// extends it, and lifting shows the edit menu.
    @objc func longPressed(_ recognizer: UILongPressGestureRecognizer) {
      guard let surface = unsafe controller?.surface else { return }
      let point = recognizer.location(in: self)
      let shift = GHOSTTY_MODS_SHIFT
      switch recognizer.state {
      case .began:
        selecting = true
        unsafe ghostty_surface_mouse_pos(surface, point.x, point.y, shift)
        unsafe ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, shift)
      case .changed:
        unsafe ghostty_surface_mouse_pos(surface, point.x, point.y, shift)
      case .ended, .cancelled:
        unsafe ghostty_surface_mouse_button(
          surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, shift)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        editMenu.presentEditMenu(with: configuration)
      default:
        break
      }
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { false }

    // MARK: Edit menu

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
      switch action {
      case #selector(copy(_:)): controller?.hasSelection ?? false
      case #selector(paste(_:)): UIPasteboard.general.hasStrings
      case #selector(selectAll(_:)): true
      default: false
      }
    }

    override func copy(_ sender: Any?) {
      controller?.copy()
    }

    override func paste(_ sender: Any?) {
      controller?.paste()
    }

    override func selectAll(_ sender: Any?) {
      controller?.selectAll()
    }
  }
#endif
