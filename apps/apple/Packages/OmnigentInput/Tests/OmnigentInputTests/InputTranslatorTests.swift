#if os(macOS)
  import AppKit
  import Testing

  @testable import OmnigentInput

  @MainActor
  @Suite("Input translation")
  struct InputTranslatorTests {
    private func key(
      _ type: NSEvent.EventType, code: UInt16, characters: String,
      flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
          context: nil, characters: characters, charactersIgnoringModifiers: characters,
          isARepeat: false, keyCode: code))
    }

    @Test func letterBecomesRawKeyDownPlusChar() throws {
      let inputs = InputTranslator.keyInputs(for: try key(.keyDown, code: 0, characters: "a"))
      #expect(inputs.map(\.kind) == [.rawKeyDown, .char])
      #expect(inputs.allSatisfy { $0.nativeKeyCode == 0 && $0.character == 97 })
    }

    @Test func commandChordsInsertNoText() throws {
      let inputs = InputTranslator.keyInputs(
        for: try key(.keyDown, code: 8, characters: "c", flags: .command))
      #expect(inputs.map(\.kind) == [.rawKeyDown])
      #expect(inputs[0].modifiers.contains(.command))
    }

    @Test func functionKeysInsertNoText() throws {
      let inputs = InputTranslator.keyInputs(
        for: try key(.keyDown, code: 123, characters: "\u{F702}"))
      #expect(inputs.map(\.kind) == [.rawKeyDown])
    }

    @Test func returnInsertsACarriageReturn() throws {
      let inputs = InputTranslator.keyInputs(for: try key(.keyDown, code: 36, characters: "\r"))
      #expect(inputs.map(\.kind) == [.rawKeyDown, .char])
      #expect(inputs[1].character == 0x0D)
    }

    @Test func modifiersMapToCEFFlags() {
      let flags = InputTranslator.modifiers([.shift, .option, .command], pressedButtons: 1)
      #expect(flags == [.shift, .alt, .command, .leftMouse])
    }

    @Test func wheelTicksScrollByLines() throws {
      let event = try #require(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0,
          wheel3: 0))
      let nsEvent = try #require(NSEvent(cgEvent: event))
      let input = try #require(InputTranslator.pointerInput(for: nsEvent, location: .zero))
      #expect(input.kind == .wheel)
      #expect(input.deltaY == nsEvent.scrollingDeltaY * InputTranslator.lineScrollPoints)
    }
  }
#endif
