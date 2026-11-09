#if os(macOS)
  import AppKit
  import Testing

  @testable import OmnigentInput

  /// Records what the composer sends, with the ranges it sent them with.
  private final class RangeRecordingSink: TextInputSink {
    var calls: [String] = []

    func forwardKeyEvent(_ event: NSEvent) { calls.append("key \(event.keyCode)") }
    func commitText(_ text: String, replacementRange: NSRange) {
      calls.append("commit \(text) \(replacementRange.location)")
    }
    func setComposition(_ text: String, selectedRange: NSRange, replacementRange: NSRange) {
      calls.append("compose \(text) \(selectedRange.location) \(replacementRange.location)")
    }
    func finishComposing(keepSelection: Bool) { calls.append("finish \(keepSelection)") }
    func cancelComposition() { calls.append("cancel") }
  }

  /// An input context whose "input method" is the test: `handleEvent` runs the callbacks a real
  /// one would make, so each key-down outcome is reachable without a window or an installed IME.
  nonisolated private final class ScriptedInputContext: NSTextInputContext {
    var inputMethod: @MainActor () -> Void = {}

    override func handleEvent(_ event: NSEvent) -> Bool {
      let inputMethod = inputMethod
      MainActor.assumeIsolated { inputMethod() }
      return true
    }
  }

  @MainActor
  @Suite("Text input composer key-downs")
  struct TextInputComposerKeyDownTests {
    private let nowhere = NSRange(location: NSNotFound, length: 0)
    private let replaced = NSRange(location: 3, length: 1)
    private let caret = NSRange(location: 1, length: 0)

    private func keyDown(code: UInt16 = 0) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
          context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
          keyCode: code))
    }

    private func context(_ inputMethod: @escaping @MainActor () -> Void) -> ScriptedInputContext {
      let context = ScriptedInputContext(client: NSTextView())
      context.inputMethod = inputMethod
      return context
    }

    /// A composer already holding marked text "ni", with the sink's record cleared.
    private func composing() -> (TextInputComposer, RangeRecordingSink) {
      let sink = RangeRecordingSink()
      let composer = TextInputComposer(sink: sink)
      composer.setMarkedText("ni", selectedRange: caret, replacementRange: nowhere)
      sink.calls = []
      return (composer, sink)
    }

    @Test("One inserted unit is a plain key, so the page sees RawKeyDown and Char")
    func singleUnitIsAPlainKey() throws {
      let sink = RangeRecordingSink()
      let composer = TextInputComposer(sink: sink)
      let script = context { composer.insertText("a", replacementRange: nowhere) }
      composer.keyDown(try keyDown(code: 7), context: script)
      #expect(sink.calls == ["key 7"])
    }

    @Test("A key the input method swallows with no callback is still a plain key")
    func noCallbackIsAPlainKey() throws {
      let sink = RangeRecordingSink()
      let composer = TextInputComposer(sink: sink)
      composer.keyDown(try keyDown(code: 123), context: context {})
      #expect(sink.calls == ["key 123"])
    }

    @Test("Text longer than one unit commits once, with its replacement range")
    func multiUnitCommits() throws {
      let sink = RangeRecordingSink()
      let composer = TextInputComposer(sink: sink)
      let script = context {
        composer.insertText("a", replacementRange: nowhere)
        composer.insertText("b", replacementRange: replaced)
      }
      composer.keyDown(try keyDown(), context: script)
      #expect(sink.calls == ["commit ab 3"])
    }

    @Test("An emoji is two UTF-16 units, so it commits rather than forwarding the key")
    func surrogatePairCommits() throws {
      let sink = RangeRecordingSink()
      let composer = TextInputComposer(sink: sink)
      let script = context { composer.insertText("😀", replacementRange: nowhere) }
      composer.keyDown(try keyDown(), context: script)
      #expect(sink.calls == ["commit 😀 \(NSNotFound)"])
    }

    @Test("Starting a composition sends it once the key is done, not from the callback")
    func startingAComposition() throws {
      let sink = RangeRecordingSink()
      let composer = TextInputComposer(sink: sink)
      let script = context {
        composer.setMarkedText("n", selectedRange: caret, replacementRange: nowhere)
        #expect(sink.calls.isEmpty)
        composer.setMarkedText("ni", selectedRange: caret, replacementRange: replaced)
      }
      composer.keyDown(try keyDown(), context: script)
      #expect(sink.calls == ["compose ni 1 3"])
      #expect(composer.markedText == "ni")
    }

    @Test("A single committed unit ending a composition commits instead of forwarding the key")
    func commitEndsAComposition() throws {
      let (composer, sink) = composing()
      let script = context { composer.insertText("你", replacementRange: nowhere) }
      composer.keyDown(try keyDown(), context: script)
      #expect(sink.calls == ["commit 你 \(NSNotFound)"])
      #expect(!composer.hasMarkedText)
    }

    // Korean and similar input methods commit a syllable and open the next within one key.
    @Test("A commit that opens the next composition sends both, in order")
    func commitThenNextComposition() throws {
      let (composer, sink) = composing()
      let script = context {
        composer.insertText("한", replacementRange: nowhere)
        composer.setMarkedText("ㄱ", selectedRange: caret, replacementRange: nowhere)
      }
      composer.keyDown(try keyDown(), context: script)
      #expect(sink.calls == ["commit 한 \(NSNotFound)", "compose ㄱ 1 \(NSNotFound)"])
      #expect(composer.hasMarkedText)
      #expect(composer.markedRange == NSRange(location: 0, length: 1))
    }

    @Test("A commit that ends a composition doesn't also finish or cancel it")
    func commitIsNotAlsoAFinish() throws {
      let (composer, sink) = composing()
      let script = context {
        composer.unmarkText()
        composer.insertText("你", replacementRange: nowhere)
      }
      composer.keyDown(try keyDown(), context: script)
      #expect(sink.calls == ["commit 你 \(NSNotFound)"])
    }

    @Test("Unmarking during a key finishes the composition")
    func unmarkFinishes() throws {
      let (composer, sink) = composing()
      composer.keyDown(try keyDown(), context: context { composer.unmarkText() })
      #expect(sink.calls == ["finish false"])
      #expect(composer.markedRange.location == NSNotFound)
    }

    @Test("Emptying the marked text during a key cancels the composition")
    func emptyMarkedTextCancels() throws {
      let (composer, sink) = composing()
      let script = context {
        composer.setMarkedText("", selectedRange: caret, replacementRange: nowhere)
      }
      composer.keyDown(try keyDown(), context: script)
      #expect(sink.calls == ["cancel"])
    }

    @Test("An earlier key's unmark doesn't turn this key's cancel into a finish")
    func unmarkDoesNotCarryOver() throws {
      let (composer, sink) = composing()
      composer.keyDown(try keyDown(), context: context { composer.unmarkText() })
      composer.setMarkedText("n", selectedRange: caret, replacementRange: nowhere)
      sink.calls = []
      let script = context {
        composer.setMarkedText("", selectedRange: caret, replacementRange: nowhere)
      }
      composer.keyDown(try keyDown(), context: script)
      #expect(sink.calls == ["cancel"])
    }

    @Test("A key the input method ignores mid-composition resends the composition")
    func untouchedCompositionResends() throws {
      let (composer, sink) = composing()
      composer.keyDown(try keyDown(), context: context {})
      #expect(sink.calls == ["compose ni 1 \(NSNotFound)"])
    }

    @Test("With no input context a composition still resends rather than typing the key")
    func noContextMidComposition() throws {
      let (composer, sink) = composing()
      composer.keyDown(try keyDown(), context: nil)
      #expect(sink.calls == ["compose ni 1 \(NSNotFound)"])
    }

    @Test("A key with no sink keeps the composer's state and sends nothing")
    func noSink() throws {
      let composer = TextInputComposer()
      let script = context {
        composer.setMarkedText("ni", selectedRange: caret, replacementRange: nowhere)
      }
      composer.keyDown(try keyDown(), context: script)
      #expect(composer.markedText == "ni")
      composer.unmarkText()
      composer.insertText("x", replacementRange: nowhere)
      composer.setMarkedText("", selectedRange: caret, replacementRange: nowhere)
      #expect(!composer.hasMarkedText)
    }

    @Test("Attributed text is read as plain text; anything else is empty")
    func textKinds() {
      let sink = RangeRecordingSink()
      let composer = TextInputComposer(sink: sink)
      let styled = NSAttributedString(string: "ni", attributes: [.underlineStyle: 1])
      composer.setMarkedText(styled, selectedRange: caret, replacementRange: nowhere)
      #expect(composer.markedText == "ni")
      composer.insertText(NSAttributedString(string: "你"), replacementRange: replaced)
      composer.setMarkedText(42, selectedRange: caret, replacementRange: nowhere)
      #expect(!composer.hasMarkedText)
      #expect(sink.calls == ["compose ni 1 \(NSNotFound)", "commit 你 3", "cancel"])
    }

    @Test("Marked text is measured in UTF-16 units, as AppKit counts ranges")
    func markedRangeUnits() {
      let composer = TextInputComposer()
      #expect(composer.markedRange == nowhere)
      composer.setMarkedText("😀", selectedRange: caret, replacementRange: nowhere)
      #expect(composer.markedRange == NSRange(location: 0, length: 2))
      #expect(TextInputComposer.validAttributesForMarkedText.contains(.underlineStyle))
    }
  }
#endif
