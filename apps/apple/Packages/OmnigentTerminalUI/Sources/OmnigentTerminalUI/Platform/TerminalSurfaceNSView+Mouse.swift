// Part of TerminalSurfaceNSView; adapted from Ghostty's macOS app
// (`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`), MIT License, Copyright (c)
// 2024 Mitchell Hashimoto, Ghostty contributors. See THIRD_PARTY_NOTICES.md.

#if os(macOS)
  import AppKit
  import OmnigentGhosttyKit

  /// Mouse buttons, motion and scrolling.
  extension TerminalSurfaceNSView {

    override func updateTrackingAreas() {
      if let trackingArea { removeTrackingArea(trackingArea) }
      let area = NSTrackingArea(
        rect: bounds,
        options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self, userInfo: nil)
      addTrackingArea(area)
      trackingArea = area
      super.updateTrackingAreas()
    }

    override func mouseDown(with event: NSEvent) {
      unsafe window?.makeFirstResponder(self)
      button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    override func mouseUp(with event: NSEvent) {
      button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
    }

    override func rightMouseDown(with event: NSEvent) {
      guard let surface = unsafe controller?.surface else { return }
      // A program that captures the mouse gets the click; otherwise show the edit menu.
      if unsafe ghostty_surface_mouse_captured(surface) {
        button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event)
      } else {
        super.rightMouseDown(with: event)
      }
    }

    override func rightMouseUp(with event: NSEvent) {
      button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event)
    }

    override func otherMouseDown(with event: NSEvent) {
      button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, event)
    }

    override func otherMouseUp(with event: NSEvent) {
      button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, event)
    }

    override func mouseMoved(with event: NSEvent) {
      guard let surface = unsafe controller?.surface else { return }
      let point = convert(event.locationInWindow, from: nil)
      unsafe ghostty_surface_mouse_pos(
        surface, point.x, frame.height - point.y, ghosttyMods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
      guard let surface = unsafe controller?.surface else { return }
      var deltaX = event.scrollingDeltaX
      var deltaY = event.scrollingDeltaY
      let precise = event.hasPreciseScrollingDeltas
      if precise {
        // Ghostty's macOS app doubles precise deltas; it reads better at terminal line heights.
        deltaX *= 2
        deltaY *= 2
      }
      var mods: Int32 = precise ? 1 : 0
      mods |= Int32(momentum(event.momentumPhase)) << 1
      unsafe ghostty_surface_mouse_scroll(surface, deltaX, deltaY, mods)
    }

    func button(
      _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent
    ) {
      guard let surface = unsafe controller?.surface else { return }
      mouseMoved(with: event)
      unsafe ghostty_surface_mouse_button(surface, state, button, ghosttyMods(event.modifierFlags))
    }

    func momentum(_ phase: NSEvent.Phase) -> UInt32 {
      switch phase {
      case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue
      case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue
      case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue
      case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue
      case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue
      case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue
      default: GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue
      }
    }
  }
#endif
