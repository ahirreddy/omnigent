#if os(iOS)
  import OmnigentCoreFFI
  public import UIKit

  /// iOS input for M1: tap to click, long press to right-click, pan (or trackpad scroll) to
  /// scroll, pointer hover to move, and hardware-keyboard keys. The on-screen keyboard and
  /// marked text come later.
  extension RemoteBrowserView {
    func installGestures() {
      let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
      let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
      let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
      pan.allowedScrollTypesMask = .all
      pan.maximumNumberOfTouches = 2
      let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
      for recognizer in [tap, press, pan, hover] as [UIGestureRecognizer] {
        addGestureRecognizer(recognizer)
      }
    }

    override public var canBecomeFirstResponder: Bool { true }

    func cursorChanged() {}

    private func css(_ recognizer: UIGestureRecognizer) -> CGPoint? {
      geometry?.cssPoint(for: recognizer.location(in: self))
    }

    private func mouse(
      _ kind: MouseKind, _ point: CGPoint, button: MouseButton? = nil, deltaX: Double = 0,
      deltaY: Double = 0
    ) -> MouseInput {
      // The button is held from down until up.
      let held = kind == .down ? button.map(RemoteInputMapping.buttonBit) ?? [] : []
      return MouseInput(
        kind: kind, x: point.x, y: point.y, button: button, clicks: button == nil ? 0 : 1,
        modifiers: held.rawValue, dx: deltaX, dy: deltaY)
    }

    private func click(at point: CGPoint, button: MouseButton) {
      store.send(mouse(.move, point))
      store.send(mouse(.down, point, button: button))
      store.send(mouse(.up, point, button: button))
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
      becomeFirstResponder()
      guard let point = css(recognizer) else { return }
      click(at: point, button: .left)
    }

    @objc private func handlePress(_ recognizer: UILongPressGestureRecognizer) {
      guard recognizer.state == .began, let point = css(recognizer) else { return }
      click(at: point, button: .right)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
      guard recognizer.state == .changed, let geometry, let point = css(recognizer) else { return }
      let translation = recognizer.translation(in: self)
      recognizer.setTranslation(.zero, in: self)
      // Natural scrolling: dragging up scrolls the content down (positive DOM deltaY).
      store.send(
        mouse(
          .wheel, point, deltaX: -geometry.cssLength(translation.x),
          deltaY: -geometry.cssLength(translation.y)))
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
      guard let point = geometry?.cssPoint(for: recognizer.location(in: self), clamped: true)
      else { return }
      store.send(mouse(recognizer.state == .ended ? .leave : .move, point))
    }

    // MARK: Hardware keyboard

    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      guard sendKeys(presses, down: true) else {
        super.pressesBegan(presses, with: event)
        return
      }
    }

    override public func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      guard sendKeys(presses, down: false) else {
        super.pressesEnded(presses, with: event)
        return
      }
    }

    private func sendKeys(_ presses: Set<UIPress>, down: Bool) -> Bool {
      guard store.canSendInput else { return false }
      var handled = false
      for press in presses {
        guard let key = press.key else { continue }
        handled = true
        let usage = UInt32(key.keyCode.rawValue)
        let modifiers = Self.modifiers(key.modifierFlags)
        let name =
          RemoteInputMapping.namedKey(hidUsage: usage)
          ?? (key.characters.isEmpty ? "Unidentified" : key.characters)
        store.send(
          KeyInput(
            kind: down ? .rawKeyDown : .keyUp, macKeyCode: nil, hidUsage: usage, code: nil,
            key: name, text: nil, modifiers: modifiers.rawValue, repeat: false))
        guard down, !key.modifierFlags.contains(.command) else { continue }
        // Return types a carriage return, as on the Mac; other named keys type nothing.
        let text = name == "Enter" ? "\r" : (name == key.characters ? key.characters : "")
        if !text.isEmpty {
          store.send(
            KeyInput(
              kind: .char, macKeyCode: nil, hidUsage: usage, code: nil, key: name, text: text,
              modifiers: modifiers.rawValue, repeat: false))
        }
      }
      return handled
    }

    private static func modifiers(_ flags: UIKeyModifierFlags) -> RemoteModifiers {
      var result: RemoteModifiers = []
      if flags.contains(.shift) { result.insert(.shift) }
      if flags.contains(.control) { result.insert(.control) }
      if flags.contains(.alternate) { result.insert(.alt) }
      if flags.contains(.command) { result.insert(.meta) }
      if flags.contains(.alphaShift) { result.insert(.capsLock) }
      return result
    }
  }
#endif
