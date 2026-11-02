#if os(iOS)
  import OmnigentCoreFFI
  public import UIKit

  /// iOS input: touch gestures (`RemoteTouchController`), pointer hover, the software keyboard
  /// (`RemoteKeyboardProxy`) while a remote field has focus, hardware keys, and the edit
  /// actions (Copy, Cut, Paste, Select All from the edit menu or ⌘ shortcuts), which use this
  /// device's pasteboard.
  extension RemoteBrowserView {
    func installGestures() {
      touchInput = RemoteTouchController(view: self)
      keyboardProxy.owner = self
      keyboardProxy.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
      addSubview(keyboardProxy)
    }

    override public var canBecomeFirstResponder: Bool { true }

    func cursorChanged() {}

    // MARK: Software keyboard

    /// Shows the keyboard when the page focuses an editable field right after the user tapped
    /// it, and hides it when the field loses focus.
    func textInputChanged() {
      let mode = store.snapshot.textInput.mode
      guard mode != .none, store.canSendInput else {
        hideKeyboardIfStillUnfocused()
        return
      }
      keyboardHide?.cancel()
      keyboardHide = nil
      if keyboardProxy.configure(for: mode), keyboardProxy.isFirstResponder {
        keyboardProxy.reloadInputViews()
      }
      // Focus that returns soon after an automatic hide (a resize can blur and refocus the
      // field) brings the keyboard back too.
      let recent = [lastTapAt, keyboardHiddenAt].compactMap { $0 }
        .contains { ContinuousClock.now - $0 < .seconds(2) }
      if recent, !keyboardProxy.isFirstResponder {
        keyboardProxy.becomeFirstResponder()
      }
    }

    /// Hides the keyboard once the page's field has stayed unfocused for 400 ms: in Mobile
    /// Size the keyboard resizes the remote, and Chromium briefly reports no focus meanwhile.
    private func hideKeyboardIfStillUnfocused() {
      guard keyboardProxy.isFirstResponder, keyboardHide == nil else { return }
      keyboardHide = Task { [weak self] in
        do {
          try await Task.sleep(for: .milliseconds(400))
        } catch {
          return  // The field was focused again.
        }
        guard let self else { return }
        self.keyboardHide = nil
        guard self.store.snapshot.textInput.mode == .none, self.keyboardProxy.isFirstResponder
        else { return }
        self.keyboardHiddenAt = .now
        self.becomeFirstResponder()
      }
    }

    /// Types software-keyboard text: Return and Tab as keys, everything else committed as text.
    func typeText(_ text: String) {
      var pending = ""
      func flush() {
        guard !pending.isEmpty else { return }
        store.send(ImeInput(op: .commit, text: pending, selection: nil, replacement: nil))
        pending = ""
      }
      for character in text {
        switch character {
        case "\n", "\r":
          flush()
          pressNamedKey("Enter", hidUsage: 0x28, text: "\r")
        case "\t":
          flush()
          pressNamedKey("Tab", hidUsage: 0x2B)
        default:
          pending.append(character)
        }
      }
      flush()
    }

    /// A key down, its character when it types one, and a key up.
    func pressNamedKey(_ name: String, hidUsage: UInt32, text: String? = nil) {
      let base = KeyInput(
        kind: .rawKeyDown, macKeyCode: nil, hidUsage: hidUsage, code: nil, key: name, text: nil,
        modifiers: 0, repeat: false)
      store.send(base)
      if let text {
        var typed = base
        typed.kind = .char
        typed.text = text
        store.send(typed)
      }
      var release = base
      release.kind = .keyUp
      store.send(release)
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

    /// Sends hardware keys to the page; ⌘ editing chords are left to the edit actions when
    /// the host has them. Returns whether the presses were handled.
    func sendKeys(_ presses: Set<UIPress>, down: Bool) -> Bool {
      guard store.canSendInput else { return false }
      var handled = false
      for press in presses {
        guard let key = press.key else { continue }
        if store.canEdit, key.modifierFlags.contains(.command),
          Self.editChords.contains(key.charactersIgnoringModifiers.lowercased())
        {
          continue
        }
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

    private static let editChords: Set<String> = ["a", "c", "v", "x", "z"]

    private static func modifiers(_ flags: UIKeyModifierFlags) -> RemoteModifiers {
      var result: RemoteModifiers = []
      if flags.contains(.shift) { result.insert(.shift) }
      if flags.contains(.control) { result.insert(.control) }
      if flags.contains(.alternate) { result.insert(.alt) }
      if flags.contains(.command) { result.insert(.meta) }
      if flags.contains(.alphaShift) { result.insert(.capsLock) }
      return result
    }

    // MARK: Edit actions

    // swiftlint:disable:next discouraged_optional_collection
    override public var keyCommands: [UIKeyCommand]? {  // UIKit's signature.
      guard store.canEdit else { return [] }
      return [
        UIKeyCommand(
          title: "Undo", action: #selector(remoteUndo), input: "z", modifierFlags: .command),
        UIKeyCommand(
          title: "Redo", action: #selector(remoteRedo), input: "z",
          modifierFlags: [.command, .shift]),
      ]
    }

    @objc private func remoteUndo() { store.edit(.undo) }
    @objc private func remoteRedo() { store.edit(.redo) }

    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
      guard store.canEdit else { return super.canPerformAction(action, withSender: sender) }
      let selection = store.snapshot.selection
      let editable = selection?.editable ?? (store.snapshot.textInput.mode != .none)
      let selected = selection.map { !$0.collapsed } ?? true
      switch action {
      case #selector(copy(_:)): return selected
      case #selector(cut(_:)): return selected && editable
      case #selector(paste(_:)): return editable && UIPasteboard.general.hasStrings
      case #selector(selectAll(_:)): return true
      default: return super.canPerformAction(action, withSender: sender)
      }
    }

    override public func copy(_ sender: Any?) { store.copy() }
    override public func cut(_ sender: Any?) { store.cut() }
    override public func paste(_ sender: Any?) { store.paste() }

    override public func selectAll(_ sender: Any?) {
      store.selectAll()
      // Offer Copy (and Cut) for what is now selected.
      Task { [weak self] in
        do {
          try await Task.sleep(for: .milliseconds(250))
        } catch {
          return
        }
        self?.touchInput?.presentEditMenu()
      }
    }
  }
#endif
