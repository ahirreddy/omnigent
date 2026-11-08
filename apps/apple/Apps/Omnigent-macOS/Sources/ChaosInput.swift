#if DEBUG
  import AppKit

  /// A key on the US layout: what it types, what it types without modifiers, and its key code.
  struct ChaosKey: Sendable {
    let characters: String
    let unmodified: String
    let code: UInt16
    /// Arrows and page keys also carry the function and numeric-pad flags, as real ones do.
    var isFunction = false

    static let returnKey = Self(characters: "\r", unmodified: "\r", code: 36)
    static let tab = Self(characters: "\t", unmodified: "\t", code: 48)
    static let delete = Self(characters: "\u{7f}", unmodified: "\u{7f}", code: 51)
    static let escape = Self(characters: "\u{1b}", unmodified: "\u{1b}", code: 53)
    static let upArrow = function(NSUpArrowFunctionKey, code: 126)
    static let downArrow = function(NSDownArrowFunctionKey, code: 125)
    static let leftArrow = function(NSLeftArrowFunctionKey, code: 123)
    static let rightArrow = function(NSRightArrowFunctionKey, code: 124)
    static let pageUp = function(NSPageUpFunctionKey, code: 116)
    static let pageDown = function(NSPageDownFunctionKey, code: 121)
    static let home = function(NSHomeFunctionKey, code: 115)
    static let end = function(NSEndFunctionKey, code: 119)

    private static func function(_ key: Int, code: UInt16) -> Self {
      let text = Unicode.Scalar(UInt32(key)).map { String(Character($0)) } ?? ""
      return Self(characters: text, unmodified: text, code: code, isFunction: true)
    }

    /// The printable keys' codes, unshifted.
    private static let codes: [Character: UInt16] = [
      "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
      "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
      "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
      "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
      "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]

    /// Shifted characters and the key under them.
    private static let shifted: [Character: Character] = [
      "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
      ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",",
      ">": ".", "?": "/", "~": "`",
    ]

    /// The key for a shortcut's character, such as "k" in Command-K.
    static func shortcut(_ character: Character) -> Self {
      Self(
        characters: String(character), unmodified: String(character),
        code: codes[character] ?? 0)
    }

    /// The key typing `character` and whether it needs Shift. Characters off the US layout
    /// (accents, emoji, CJK) come as text on key code 0, as an input method delivers them.
    static func typing(_ character: Character) -> (key: Self, shift: Bool) {
      let text = String(character)
      if let code = codes[character] {
        return (Self(characters: text, unmodified: text, code: code), false)
      }
      let lower = Character(text.lowercased())
      if character.isUppercase, let code = codes[lower] {
        return (Self(characters: text, unmodified: String(lower), code: code), true)
      }
      if let base = shifted[character], let code = codes[base] {
        return (Self(characters: text, unmodified: String(base), code: code), true)
      }
      return (Self(characters: text, unmodified: text, code: 0), false)
    }
  }

  /// Input built as AppKit events and queued to the app itself, so it reaches the app's windows
  /// the way the window server's would, without Accessibility or automation mode, and without
  /// touching the real pointer or keyboard.
  @MainActor
  enum ChaosInput {
    private static var eventNumber = 0

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Presses and releases `key` with `modifiers` in `window`, or with no window for the menus.
    static func press(
      _ key: ChaosKey, _ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow?
    ) {
      var flags = modifiers
      if key.isFunction { flags.formUnion([.function, .numericPad]) }
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard
          let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: now,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.unmodified, isARepeat: false, keyCode: key.code)
        else { continue }
        NSApp.postEvent(event, atStart: false)
      }
    }

    /// Types `text` key by key, with Shift where the US layout needs it.
    static func type(_ text: String, in window: NSWindow) {
      for character in text {
        let (key, shift) = ChaosKey.typing(character)
        press(key, shift ? .shift : [], in: window)
      }
    }

    /// Clicks `count` times at `point`, in window coordinates.
    static func click(
      at point: CGPoint, in window: NSWindow, right: Bool = false, count: Int = 1,
      modifiers: NSEvent.ModifierFlags = []
    ) {
      let down: NSEvent.EventType = right ? .rightMouseDown : .leftMouseDown
      let release: NSEvent.EventType = right ? .rightMouseUp : .leftMouseUp
      for clickCount in 1...max(1, count) {
        mouse(down, at: point, in: window, clickCount: clickCount, modifiers: modifiers)
        mouse(release, at: point, in: window, clickCount: clickCount, modifiers: modifiers)
      }
    }

    /// Presses at `start`, drags through `steps` points to `end` and releases there.
    static func drag(from start: CGPoint, to end: CGPoint, steps: Int, in window: NSWindow) {
      mouse(.leftMouseDown, at: start, in: window)
      for point in path(from: start, to: end, steps: steps) {
        mouse(.leftMouseDragged, at: point, in: window)
      }
      mouse(.leftMouseUp, at: end, in: window)
    }

    /// Moves the pointer with no button down through `steps` points from `start` to `end`.
    static func hover(from start: CGPoint, to end: CGPoint, steps: Int, in window: NSWindow) {
      for point in [start] + path(from: start, to: end, steps: steps) {
        mouse(.mouseMoved, at: point, in: window)
      }
    }

    /// `steps` evenly spaced points after `start`, the last one `end`.
    private static func path(from start: CGPoint, to end: CGPoint, steps: Int) -> [CGPoint] {
      let count = max(1, steps)
      return (1...count).map { index in
        let fraction = CGFloat(index) / CGFloat(count)
        return CGPoint(
          x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
      }
    }

    /// Types `text` through an input method into the window's first responder: marked text
    /// growing a character at a time, then committed, or, when `abandons`, dropped as Escape
    /// drops it. Each stage waits `pause` seconds, as a person picking characters does.
    /// - Returns: Whether the first responder takes input-method text.
    @discardableResult
    static func compose(_ text: String, abandons: Bool, pause: TimeInterval, in window: NSWindow)
      -> Bool
    {
      guard let client = window.firstResponder as? (any NSTextInputClient) else { return false }
      let nowhere = NSRange(location: NSNotFound, length: 0)
      var stages: [() -> Void] = []
      var marked = ""
      for character in text {
        marked.append(character)
        let stage = marked
        stages.append {
          client.setMarkedText(
            stage, selectedRange: NSRange(location: stage.utf16.count, length: 0),
            replacementRange: nowhere)
        }
      }
      if abandons {
        stages.append {
          client.setMarkedText("", selectedRange: NSRange(), replacementRange: nowhere)
          client.unmarkText()
        }
      } else {
        stages.append { client.insertText(text, replacementRange: nowhere) }
      }
      for (index, stage) in stages.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + pause * Double(index), execute: stage)
      }
      return true
    }

    private static func mouse(
      _ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, clickCount: Int = 1,
      modifiers: NSEvent.ModifierFlags = []
    ) {
      eventNumber += 1
      let pressed = type == .leftMouseDown || type == .rightMouseDown || type == .leftMouseDragged
      guard
        let event = NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: modifiers, timestamp: now,
          windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
          clickCount: clickCount, pressure: pressed ? 1 : 0)
      else { return }
      NSApp.postEvent(event, atStart: false)
    }

    /// A trackpad-style scroll gesture at `point` (window coordinates), sent to the view under
    /// the point a frame apart as a trackpad sends it: a began phase, `ticks` changes of `delta`
    /// points each and an ended phase, then, with `momentum`, a deceleration that slows to rest.
    /// - Returns: Whether a view was under the point.
    @discardableResult
    static func scroll(
      at point: CGPoint, by delta: CGVector, ticks: Int, momentum: Bool = false,
      in window: NSWindow
    ) -> Bool {
      guard let view = window.contentView?.hitTest(point) else { return false }
      let screenPoint = window.convertPoint(toScreen: point)
      let screenHeight = NSScreen.screens.first?.frame.height ?? 0
      let location = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
      for (index, step) in scrollSteps(ticks: ticks, momentum: momentum).enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016 * Double(index)) {
          guard
            let event = scrollEvent(
              CGVector(dx: delta.dx * step.scale, dy: delta.dy * step.scale), step: step,
              at: location)
          else { return }
          view.scrollWheel(with: event)
        }
      }
      return true
    }

    /// One event of a scroll gesture: its phase or momentum phase and its share of the delta.
    struct ScrollStep: Equatable {
      var phase: Int64 = 0
      var momentum: Int64 = 0
      var scale: CGFloat
    }

    /// The events of a gesture of `ticks` changes. Scroll phases: 1 began, 2 changed, 4 ended;
    /// momentum phases: 1 began, 2 continued, 3 ended.
    nonisolated static func scrollSteps(ticks: Int, momentum: Bool) -> [ScrollStep] {
      var steps = [ScrollStep(phase: 1, scale: 0)]
      steps += Array(repeating: ScrollStep(phase: 2, scale: 1), count: max(1, ticks))
      steps.append(ScrollStep(phase: 4, scale: 0))
      guard momentum else { return steps }
      steps.append(ScrollStep(momentum: 1, scale: 0.9))
      steps += (1...12).map { ScrollStep(momentum: 2, scale: pow(0.75, CGFloat($0))) }
      steps.append(ScrollStep(momentum: 3, scale: 0))
      return steps
    }

    private static func scrollEvent(_ delta: CGVector, step: ScrollStep, at location: CGPoint)
      -> NSEvent?
    {
      guard
        let cgEvent = CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(delta.dy),
          wheel2: Int32(delta.dx), wheel3: 0)
      else { return nil }
      cgEvent.location = location
      cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: step.phase)
      cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: step.momentum)
      return NSEvent(cgEvent: cgEvent)
    }
  }
#endif
