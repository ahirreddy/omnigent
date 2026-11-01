// The UIKit view a libghostty surface renders into, with software and hardware keyboard input,
// IME (marked text), touch scrolling, selection and the edit menu.
//
// The surface sizing follows Ghostty's `macos/Sources/Ghostty/Surface View/SurfaceView_UIKit.swift`
// (MIT License, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors). The input handling
// is Omnigent's own. See THIRD_PARTY_NOTICES.md.

#if os(iOS)
  import OmnigentGhosttyKit
  import UIKit

  /// The view a terminal surface renders into. libghostty adds its Metal (IOSurface) layer as a
  /// sublayer; this class feeds it input and size.
  final class TerminalSurfaceUIView: UIView, UIKeyInput, UITextInputTraits {
    weak var controller: TerminalSurfaceController?

    /// The text the IME is composing. It is shown as Ghostty preedit, never sent until committed.
    var markedText = ""
    var markedSelection = NSRange(location: 0, length: 0)
    var heldKeys: [UIKeyboardHIDUsage: UInt32] = [:]
    var lastPan = CGPoint.zero
    var momentum: CADisplayLink?
    var momentumVelocity = CGPoint.zero
    var selecting = false
    var displayLink: CADisplayLink?
    var renderPending = false
    var blinkTimer: Timer?
    lazy var editMenu = UIEditMenuInteraction(delegate: self)
    lazy var accessoryBar = TerminalAccessoryBar(
      frame: CGRect(x: 0, y: 0, width: 320, height: 44))

    override init(frame: CGRect) {
      super.init(frame: frame)
      isMultipleTouchEnabled = true
      addInteraction(editMenu)
      let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
      addGestureRecognizer(tap)
      let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
      pan.maximumNumberOfTouches = 1
      pan.delegate = self
      addGestureRecognizer(pan)
      let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
      press.minimumPressDuration = 0.35
      addGestureRecognizer(press)
      accessoryBar.onKey = { [weak self] key in self?.accessoryKey(key) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      nil
    }

    // MARK: Size and focus

    override func layoutSubviews() {
      super.layoutSubviews()
      for sublayer in layer.sublayers ?? [] { sublayer.frame = bounds }
      controller?.resize(points: bounds.size, scale: traitCollection.displayScale)
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      controller?.resize(points: bounds.size, scale: traitCollection.displayScale)
      if window != nil {
        requestRender()
      } else {
        displayLink?.isPaused = true
      }
    }

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
      let became = super.becomeFirstResponder()
      if became {
        controller?.setFocused(true)
        updateBlinkTimer(focused: true)
        requestRender()
      }
      return became
    }

    override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned {
        controller?.setFocused(false)
        updateBlinkTimer(focused: false)
        requestRender()
      }
      return resigned
    }

    override var inputAccessoryView: UIView? { accessoryBar }

    // MARK: Hardware keyboard

    /// Keys that never produce text (arrows, Escape, function keys) and chords with Control,
    /// Option or Command go straight to Ghostty's encoder, so the program's keyboard mode applies.
    /// Plain text keys go through the text input system so IMEs can compose.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      var unhandled: Set<UIPress> = []
      for press in presses {
        guard let key = press.key, markedText.isEmpty, encodeDirectly(key) else {
          unhandled.insert(press)
          continue
        }
        send(key, action: GHOSTTY_ACTION_PRESS)
      }
      if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      var unhandled: Set<UIPress> = []
      for press in presses {
        guard let key = press.key, heldKeys[key.keyCode] != nil else {
          unhandled.insert(press)
          continue
        }
        send(key, action: GHOSTTY_ACTION_RELEASE)
      }
      if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      pressesEnded(presses, with: event)
    }

    private func encodeDirectly(_ key: UIKey) -> Bool {
      if !key.modifierFlags.isDisjoint(with: [.control, .alternate, .command]) { return true }
      let scalar = key.charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0
      // Empty, control characters and the private-use function-key range produce no text.
      return key.characters.isEmpty || scalar < 0x20 || scalar == 0x7F
        || (0xF700...0xF8FF).contains(scalar)
    }

    private func send(_ key: UIKey, action: ghostty_input_action_e) {
      guard let surface = unsafe controller?.surface,
        let macCode = HIDKeyCodes.macKeyCode[key.keyCode.rawValue]
      else { return }
      if action == GHOSTTY_ACTION_RELEASE {
        heldKeys[key.keyCode] = nil
      } else {
        heldKeys[key.keyCode] = macCode
      }
      var event = unsafe ghostty_input_key_s()
      unsafe event.action = action
      unsafe event.keycode = macCode
      unsafe event.mods = ghosttyMods(key.modifierFlags)
      unsafe event.consumed_mods = ghosttyMods(key.modifierFlags.subtracting([.control, .command]))
      unsafe event.unshifted_codepoint =
        key.charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0
      unsafe event.composing = false
      let text = key.characters
      let first = text.unicodeScalars.first?.value ?? 0
      if action != GHOSTTY_ACTION_RELEASE, !text.isEmpty, first >= 0x20, first != 0x7F,
        !(0xF700...0xF8FF).contains(first)
      {
        text.withCString { pointer in
          unsafe event.text = pointer
          unsafe ghostty_surface_key(surface, event)
        }
      } else {
        unsafe event.text = nil
        unsafe ghostty_surface_key(surface, event)
      }
    }

    // MARK: Accessory row

    private func accessoryKey(_ key: TerminalAccessoryBar.Key) {
      guard let controller else { return }
      switch key {
      case .special(let special):
        controller.press(special, modifiers: accessoryBar.takeModifiers())
      case .text(let text):
        let modifiers = accessoryBar.takeModifiers()
        if modifiers.contains(.control), let code = Self.letterKeyCode(text) {
          pressLetter(code: code, character: text, modifiers: modifiers)
        } else {
          controller.type(text)
        }
      case .paste:
        controller.paste()
      case .dismissKeyboard:
        _ = resignFirstResponder()
      }
    }

    /// The macOS keycode for an ASCII letter, which Control chords need.
    static func letterKeyCode(_ text: String) -> UInt32? {
      guard text.count == 1, let scalar = text.lowercased().unicodeScalars.first,
        (UInt32(UInt8(ascii: "a"))...UInt32(UInt8(ascii: "z"))).contains(scalar.value)
      else { return nil }
      let usage = 0x04 + Int(scalar.value - UInt32(UInt8(ascii: "a")))
      return HIDKeyCodes.macKeyCode[usage]
    }

    private func pressLetter(code: UInt32, character: String, modifiers: TerminalModifiers) {
      guard let surface = unsafe controller?.surface else { return }
      var event = unsafe ghostty_input_key_s()
      unsafe event.keycode = code
      unsafe event.mods = modifiers.ghostty
      unsafe event.consumed_mods = GHOSTTY_MODS_NONE
      unsafe event.unshifted_codepoint = character.unicodeScalars.first?.value ?? 0
      unsafe event.composing = false
      unsafe event.text = nil
      unsafe event.action = GHOSTTY_ACTION_PRESS
      unsafe ghostty_surface_key(surface, event)
      unsafe event.action = GHOSTTY_ACTION_RELEASE
      unsafe ghostty_surface_key(surface, event)
    }

    // MARK: UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
      guard let controller else { return }
      let modifiers = accessoryBar.takeModifiers()
      if text == "\n" {
        controller.press(.enter, modifiers: modifiers)
      } else if modifiers.contains(.control), let code = Self.letterKeyCode(text) {
        pressLetter(code: code, character: text, modifiers: modifiers)
      } else {
        controller.type(text)
      }
    }

    func deleteBackward() {
      controller?.press(.backspace, modifiers: accessoryBar.takeModifiers())
    }

    // MARK: UITextInputTraits

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default

    // MARK: UITextInput (marked text only)
    //
    // The document UIKit sees is only the text being composed. Committed text goes to the
    // terminal immediately, so there is nothing else to edit or select.

    weak var inputDelegate: (any UITextInputDelegate)?
    lazy var tokenizer: any UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
    // UITextInput requires this optional dictionary; the terminal styles preedit itself.
    // swiftlint:disable:next discouraged_optional_collection
    var markedTextStyle: [NSAttributedString.Key: Any]?

    // MARK: Feedback

    func setPointerShape(_ shape: ghostty_action_mouse_shape_e) {}

    func ringBell() {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Frames
    //
    // On iOS the fork renders in "external drain" mode: Ghostty never presents on its own
    // thread. When it has a frame it emits GHOSTTY_ACTION_RENDER, and the embedder calls
    // ghostty_surface_render_now on the main thread, here from a display link so bursts of
    // output coalesce into one frame per refresh. While focused, a slow tick keeps the cursor
    // blinking.

    /// Schedules one frame on the next display refresh. Returns true: the request is accepted.
    @discardableResult
    func requestRender() -> Bool {
      renderPending = true
      if displayLink == nil {
        let link = CADisplayLink(target: self, selector: #selector(displayTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
      }
      displayLink?.isPaused = false
      return true
    }

    @objc private func displayTick(_ link: CADisplayLink) {
      guard renderPending else {
        link.isPaused = true
        return
      }
      renderPending = false
      controller?.renderNow()
    }

    private func updateBlinkTimer(focused: Bool) {
      blinkTimer?.invalidate()
      blinkTimer = nil
      guard focused else { return }
      let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { _ = self?.requestRender() }
      }
      RunLoop.main.add(timer, forMode: .common)
      blinkTimer = timer
    }

    /// Stops frame scheduling for good; the surface is about to be freed.
    func stopRendering() {
      displayLink?.invalidate()
      displayLink = nil
      blinkTimer?.invalidate()
      blinkTimer = nil
      renderPending = false
    }
  }

  /// A position in the composing text: a UTF-16 offset.
  final class TerminalTextPosition: UITextPosition {
    let offset: Int

    init(_ offset: Int) {
      self.offset = offset
    }
  }

  /// A range in the composing text.
  final class TerminalTextRange: UITextRange {
    let lower: Int
    let upper: Int

    init(_ lower: Int, _ upper: Int) {
      self.lower = lower
      self.upper = upper
    }

    override var start: UITextPosition { TerminalTextPosition(lower) }
    override var end: UITextPosition { TerminalTextPosition(upper) }
    override var isEmpty: Bool { lower == upper }
  }

  /// Ghostty modifier bits for UIKit flags.
  func ghosttyMods(_ flags: UIKeyModifierFlags) -> ghostty_input_mods_e {
    var mods = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.alternate) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.alphaShift) { mods |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(rawValue: mods)
  }
#endif
