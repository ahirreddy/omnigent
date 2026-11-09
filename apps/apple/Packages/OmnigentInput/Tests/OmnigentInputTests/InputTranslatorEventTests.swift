#if os(macOS)
  import AppKit
  import Testing

  @testable import OmnigentInput

  /// Every kind of event the translator takes. The events are built by hand and never posted.
  @MainActor
  @Suite("Input translation of each event")
  struct InputTranslatorEventTests {
    private func key(
      _ type: NSEvent.EventType, code: UInt16 = 0, characters: String = "",
      unmodified: String? = nil, flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false
    ) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
          context: nil, characters: characters,
          charactersIgnoringModifiers: unmodified ?? characters, isARepeat: isRepeat,
          keyCode: code))
    }

    private func mouse(
      _ type: NSEvent.EventType, clicks: Int = 1, flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
          context: nil, eventNumber: 0, clickCount: clicks, pressure: 0))
    }

    private func scroll(precise: Bool, deltaX: Int32, deltaY: Int32) throws -> NSEvent {
      let wheel = try #require(
        CGEvent(
          scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2,
          wheel1: deltaY, wheel2: deltaX, wheel3: 0))
      return try #require(NSEvent(cgEvent: wheel))
    }

    @Test(
      "Text is what isn't a function key or control character",
      arguments: [
        (UInt16(0x0D), true), (0x20, true), (0x41, true), (0xF6FF, true), (0xF900, true),
        (0xFFFF, true), (0x00, false), (0x09, false), (0x1F, false), (0x7F, false),
        (0xF700, false), (0xF8FF, false),
      ])
    func textUnits(unit: UInt16, inserts: Bool) {
      #expect(InputTranslator.insertsText(unit) == inserts)
    }

    @Test("Every modifier and held button maps; unknown button bits don't")
    func modifiers() {
      let all: NSEvent.ModifierFlags = [
        .capsLock, .shift, .control, .option, .command, .numericPad,
      ]
      let mapped = InputTranslator.modifiers(all, pressedButtons: 0b111)
      let expected: InputModifiers = [
        .capsLock, .shift, .control, .alt, .command, .isKeyPad, .leftMouse, .rightMouse,
        .middleMouse,
      ]
      #expect(mapped == expected)
      #expect(InputTranslator.modifiers([], pressedButtons: 0).isEmpty)
      #expect(InputTranslator.modifiers([], pressedButtons: 0b1000).isEmpty)
      #expect(
        InputTranslator.modifiers([], pressedButtons: -1) == [
          .leftMouse, .rightMouse, .middleMouse,
        ])
    }

    @Test("A held key repeats; a surrogate pair is two Char units sharing one key")
    func keyDowns() throws {
      let repeated = InputTranslator.keyInputs(
        for: try key(.keyDown, characters: "a", isRepeat: true))
      #expect(repeated.allSatisfy { $0.modifiers.contains(.isRepeat) })

      let emoji = InputTranslator.keyInputs(for: try key(.keyDown, characters: "\u{1F600}"))
      #expect(emoji.map(\.kind) == [.rawKeyDown, .char, .char])
      #expect(emoji.dropFirst().map(\.character) == Array("\u{1F600}".utf16))

      let empty = InputTranslator.keyInputs(for: try key(.keyDown))
      #expect(empty.map(\.kind) == [.rawKeyDown])
      #expect(empty.first?.character == 0)
      #expect(empty.first?.unmodifiedCharacter == 0)

      let mixed = InputTranslator.keyInputs(
        for: try key(.keyDown, characters: "a", unmodified: ""))
      #expect(mixed.last?.unmodifiedCharacter == 97)
    }

    @Test("A key up carries its characters, or none")
    func keyUps() throws {
      let released = InputTranslator.keyInputs(
        for: try key(.keyUp, code: 12, characters: "é", unmodified: "e", flags: .option))
      #expect(released.map(\.kind) == [.keyUp])
      #expect(released.first?.nativeKeyCode == 12)
      #expect(released.first?.character == Array("é".utf16).first)
      #expect(released.first?.unmodifiedCharacter == Array("e".utf16).first)
      #expect(released.first?.modifiers == [.alt])
      #expect(InputTranslator.keyInputs(for: try key(.keyUp)).first?.character == 0)
    }

    @Test("A modifier key presses or releases by its flag; other keys send nothing")
    func flagsChanged() throws {
      let pressed = InputTranslator.keyInputs(
        for: try key(.flagsChanged, code: 56, flags: .shift))
      #expect(pressed.map(\.kind) == [.rawKeyDown])
      let released = InputTranslator.keyInputs(for: try key(.flagsChanged, code: 56))
      #expect(released.map(\.kind) == [.keyUp])
      #expect(InputTranslator.keyInputs(for: try key(.flagsChanged, code: 0)).isEmpty)
      #expect(InputTranslator.keyInputs(for: try key(.flagsChanged, code: .max)).isEmpty)
    }

    @Test("Each modifier key names its flag")
    func modifierKeys() {
      let table: [(UInt16, NSEvent.ModifierFlags)] = [
        (56, .shift), (60, .shift), (59, .control), (62, .control), (58, .option), (61, .option),
        (55, .command), (54, .command), (57, .capsLock),
      ]
      for (code, flag) in table {
        #expect(InputTranslator.modifierFlag(forKeyCode: code) == flag)
      }
      #expect(InputTranslator.modifierFlag(forKeyCode: 0) == nil)
      #expect(InputTranslator.modifierFlag(forKeyCode: .max) == nil)
    }

    @Test("Mouse events aren't key events, and key events aren't pointers")
    func wrongKinds() throws {
      #expect(InputTranslator.keyInputs(for: try mouse(.leftMouseDown)).isEmpty)
      #expect(InputTranslator.pointerInput(for: try key(.keyDown), location: .zero) == nil)
    }

    @Test("Presses and releases name their button and never count zero clicks")
    func buttons() throws {
      // swiftlint:disable:next large_tuple
      let cases: [(NSEvent.EventType, PointerEventKind, PointerButton)] = [
        (.leftMouseDown, .press, .left), (.leftMouseUp, .release, .left),
        (.rightMouseDown, .press, .right), (.rightMouseUp, .release, .right),
        (.otherMouseDown, .press, .middle), (.otherMouseUp, .release, .middle),
      ]
      for (type, kind, button) in cases {
        let input = try #require(
          InputTranslator.pointerInput(for: try mouse(type, clicks: 0), location: .zero))
        #expect(input.kind == kind)
        #expect(input.button == button)
        #expect(input.clickCount == 1)
      }
      let triple = InputTranslator.pointerInput(
        for: try mouse(.leftMouseDown, clicks: 3), location: CGPoint(x: -1, y: CGFloat.nan))
      #expect(triple?.clickCount == 3)
      #expect(triple?.location.x == -1)
    }

    @Test("Drags and moves are moves; the button a drag implies is held")
    func moves() throws {
      // swiftlint:disable:next large_tuple
      let drags: [(NSEvent.EventType, Int, InputModifiers)] = [
        (.leftMouseDragged, 1, .leftMouse), (.rightMouseDragged, 2, .rightMouse),
        (.otherMouseDragged, 4, .middleMouse),
      ]
      for (type, bit, held) in drags {
        let event = try mouse(type)
        #expect(InputTranslator.impliedButtons(event) == bit)
        let input = InputTranslator.pointerInput(for: event, location: .zero)
        #expect(input?.kind == .move)
        #expect(input?.modifiers.contains(held) == true)
      }
      #expect(
        InputTranslator.pointerInput(for: try mouse(.mouseMoved), location: .zero)?.kind == .move)
      #expect(InputTranslator.impliedButtons(try mouse(.mouseMoved)) == 0)
      #expect(InputTranslator.impliedButtons(try mouse(.leftMouseUp)) == 0)
      #expect(InputTranslator.impliedButtons(try mouse(.rightMouseDown)) == 2)
      #expect(InputTranslator.impliedButtons(try mouse(.otherMouseDown)) == 4)
    }

    @Test("Entering is a move and leaving is a leave")
    func enterExit() throws {
      func event(_ type: NSEvent.EventType) throws -> NSEvent {
        let built = unsafe NSEvent.enterExitEvent(
          with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
          context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        return try #require(built)
      }
      #expect(
        InputTranslator.pointerInput(for: try event(.mouseEntered), location: .zero)?.kind == .move)
      #expect(
        InputTranslator.pointerInput(for: try event(.mouseExited), location: .zero)?.kind == .leave)
    }

    @Test("Line scrolling scales by the line height; pixel scrolling passes through")
    func wheels() throws {
      let line = try #require(
        InputTranslator.pointerInput(
          for: try scroll(precise: false, deltaX: 2, deltaY: -3), location: .zero))
      #expect(line.kind == .wheel)
      #expect(line.deltaY == -3 * InputTranslator.lineScrollPoints)
      #expect(line.deltaX == 2 * InputTranslator.lineScrollPoints)

      let pixel = try #require(
        InputTranslator.pointerInput(
          for: try scroll(precise: true, deltaX: 0, deltaY: 7), location: .zero))
      #expect(pixel.deltaY == 7)

      let extreme = try #require(
        InputTranslator.pointerInput(
          for: try scroll(precise: false, deltaX: .max, deltaY: .min), location: .zero))
      #expect(extreme.deltaX.isFinite)
      #expect(extreme.deltaY.isFinite)
    }

    @Test("Every page cursor has a system cursor; what has none is the arrow")
    func cursors() {
      let table: [(PageCursor, NSCursor)] = [
        (.pointer, .arrow), (.wait, .arrow), (.none, .arrow), (.help, .arrow),
        (.hand, .pointingHand), (.iBeam, .iBeam), (.crosshair, .crosshair),
        (.resizeLeftRight, .resizeLeftRight), (.resizeUpDown, .resizeUpDown),
        (.notAllowed, .operationNotAllowed), (.grab, .openHand), (.grabbing, .closedHand),
      ]
      #expect(table.count == PageCursor.allCases.count)
      for (cursor, expected) in table {
        // Compared out here: `#expect` evaluates its operands outside the main actor.
        let matches = cursor.nsCursor === expected
        #expect(matches, "\(cursor)")
      }
    }
  }
#endif
