// The AppKit view a libghostty surface renders into, with keyboard (including IME), mouse,
// scroll and edit-menu handling.
//
// Adapted from Ghostty's macOS app (`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
// and `NSEvent+Extension.swift`), MIT License, Copyright (c) 2024 Mitchell Hashimoto, Ghostty
// contributors. See THIRD_PARTY_NOTICES.md.

#if os(macOS)
  import AppKit
  import OmnigentGhosttyKit

  /// The view a terminal surface renders into. libghostty makes it layer-hosting and attaches its
  /// Metal (IOSurface) layer; this class feeds it input and size.
  final class TerminalSurfaceNSView: NSView, NSMenuItemValidation {
    weak var controller: TerminalSurfaceController?

    /// Whether a `keyDown` is running `interpretKeyEvents`.
    var interpretingKeyDown = false
    /// Text `interpretKeyEvents` committed during the current `keyDown`.
    var keyText: [String] = []
    var markedText = NSMutableAttributedString()
    var trackingArea: NSTrackingArea?
    var focused = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func becomeFirstResponder() -> Bool {
      let accepted = super.becomeFirstResponder()
      if accepted {
        focused = true
        controller?.setFocused(true)
      }
      return accepted
    }

    override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned {
        focused = false
        controller?.setFocused(false)
      }
      return resigned
    }

    // MARK: Size

    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      reportSize()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      reportSize()
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      if let window = unsafe window {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
      }
      reportSize()
    }

    private func reportSize() {
      let scale = unsafe window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
      controller?.resize(points: bounds.size, scale: scale)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
      guard let controller, unsafe controller.surface != nil else {
        interpretKeyEvents([event])
        return
      }
      let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
      let hadMarkedText = markedText.length > 0
      keyText = []
      interpretingKeyDown = true
      defer {
        interpretingKeyDown = false
        keyText = []
      }
      interpretKeyEvents([event])
      syncPreedit(clearIfNeeded: hadMarkedText)
      let composing = markedText.length > 0 || hadMarkedText
      if !keyText.isEmpty {
        for text in keyText {
          send(action, event: event, text: text, composing: false)
        }
      } else {
        send(action, event: event, text: event.ghosttyCharacters, composing: composing)
      }
    }

    override func keyUp(with event: NSEvent) {
      send(GHOSTTY_ACTION_RELEASE, event: event, text: nil, composing: false)
    }

    override func flagsChanged(with event: NSEvent) {
      let modifier: NSEvent.ModifierFlags
      switch event.keyCode {
      case 0x39: modifier = .capsLock
      case 0x38, 0x3C: modifier = .shift
      case 0x3B, 0x3E: modifier = .control
      case 0x3A, 0x3D: modifier = .option
      case 0x37, 0x36: modifier = .command
      default: return
      }
      guard !hasMarkedText() else { return }
      let action =
        event.modifierFlags.contains(modifier) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
      send(action, event: event, text: nil, composing: false)
    }

    /// Lets Ghostty's keybindings (Cmd-C, Cmd-V, Cmd-F, Cmd-A, ...) see Command and Control
    /// chords before AppKit turns them into menu commands or `doCommand(by:)`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      guard event.type == .keyDown, focused,
        let surface = unsafe controller?.surface,
        !event.modifierFlags.isDisjoint(with: [.command, .control])
      else { return false }
      var key = unsafe event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
      var flags = ghostty_binding_flags_e(0)
      let isBinding = (event.ghosttyCharacters ?? "").withCString { pointer in
        unsafe key.text = pointer
        return unsafe ghostty_surface_key_is_binding(surface, key, &flags)
      }
      guard isBinding else { return false }
      keyDown(with: event)
      return true
    }

    func send(
      _ action: ghostty_input_action_e, event: NSEvent, text: String?, composing: Bool
    ) {
      guard let surface = unsafe controller?.surface else { return }
      var key = unsafe event.ghosttyKeyEvent(action)
      unsafe key.composing = composing
      if let text, !text.isEmpty, let first = text.unicodeScalars.first, first.value >= 0x20 {
        text.withCString { pointer in
          unsafe key.text = pointer
          unsafe ghostty_surface_key(surface, key)
        }
      } else {
        unsafe ghostty_surface_key(surface, key)
      }
    }

    func syncPreedit(clearIfNeeded: Bool) {
      guard let surface = unsafe controller?.surface else { return }
      if markedText.length > 0 {
        let text = markedText.string
        text.withCString { pointer in
          unsafe ghostty_surface_preedit(surface, pointer, UInt(text.utf8.count))
        }
      } else if clearIfNeeded {
        unsafe ghostty_surface_preedit(surface, nil, 0)
      }
    }

    override func doCommand(by selector: Selector) {
      // Commands (moveLeft:, insertNewline:, ...) reach the terminal as key events from
      // keyDown; AppKit's text-editing meaning does not apply to a terminal.
    }

    // MARK: Edit menu

    override func menu(for event: NSEvent) -> NSMenu? {
      let menu = NSMenu()
      menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
      menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
      menu.addItem(.separator())
      menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
      menu.addItem(withTitle: "Find…", action: #selector(findTerminal(_:)), keyEquivalent: "")
      return menu
    }

    /// Copies the selection.
    @objc func copy(_ sender: Any?) { controller?.copy() }
    /// Pastes the clipboard.
    @objc func paste(_ sender: Any?) { controller?.paste() }
    /// Selects everything.
    @objc override func selectAll(_ sender: Any?) { controller?.selectAll() }
    /// Opens the find bar.
    @objc func findTerminal(_ sender: Any?) { controller?.startSearch() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
      switch menuItem.action {
      case #selector(copy(_:)): controller?.hasSelection ?? false
      case #selector(paste(_:)): NSPasteboard.general.string(forType: .string) != nil
      default: true
      }
    }

    // MARK: Feedback

    func setPointerShape(_ shape: ghostty_action_mouse_shape_e) {
      switch shape {
      case GHOSTTY_MOUSE_SHAPE_TEXT: NSCursor.iBeam.set()
      case GHOSTTY_MOUSE_SHAPE_POINTER: NSCursor.pointingHand.set()
      default: NSCursor.arrow.set()
      }
    }

    func ringBell() {
      NSSound.beep()
    }

    /// macOS frames come from Ghostty's renderer thread; nothing to schedule.
    @discardableResult
    func requestRender() -> Bool { false }

    /// Nothing to stop on macOS.
    func stopRendering() {}
  }

  /// Ghostty modifier bits for AppKit flags.
  func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
    let raw = flags.rawValue
    if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
    return ghostty_input_mods_e(rawValue: mods)
  }

  extension NSEvent {
    /// A Ghostty key event without text. The caller sets `text` for the call's duration.
    func ghosttyKeyEvent(_ action: ghostty_input_action_e) -> ghostty_input_key_s {
      var key = unsafe ghostty_input_key_s()
      unsafe key.action = action
      unsafe key.keycode = UInt32(keyCode)
      unsafe key.text = nil
      unsafe key.composing = false
      unsafe key.mods = ghosttyMods(modifierFlags)
      // Control and Command never produce text on macOS; everything else may have.
      unsafe key.consumed_mods = ghosttyMods(modifierFlags.subtracting([.control, .command]))
      unsafe key.unshifted_codepoint = 0
      if type == .keyDown || type == .keyUp,
        let scalar = characters(byApplyingModifiers: [])?.unicodeScalars.first
      {
        unsafe key.unshifted_codepoint = scalar.value
      }
      return unsafe key
    }

    /// The event's text for Ghostty: control characters are left to Ghostty's own encoder, and
    /// function-key private-use characters are dropped.
    var ghosttyCharacters: String? {
      guard let characters else { return nil }
      if characters.count == 1, let scalar = characters.unicodeScalars.first {
        if scalar.value < 0x20 {
          return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
        }
        if (0xF700...0xF8FF).contains(scalar.value) { return nil }
      }
      return characters
    }
  }
#endif
