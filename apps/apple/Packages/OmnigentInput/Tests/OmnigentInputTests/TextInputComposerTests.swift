#if os(macOS)
  import AppKit
  import Testing

  @testable import OmnigentInput

  /// Records what the composer sends.
  private final class RecordingSink: TextInputSink {
    var calls: [String] = []

    func forwardKeyEvent(_ event: NSEvent) { calls.append("key \(event.keyCode)") }
    func commitText(_ text: String, replacementRange: NSRange) { calls.append("commit \(text)") }
    func setComposition(_ text: String, selectedRange: NSRange, replacementRange: NSRange) {
      calls.append("compose \(text) \(selectedRange.location)")
    }
    func finishComposing(keepSelection: Bool) { calls.append("finish") }
    func cancelComposition() { calls.append("cancel") }
  }

  @MainActor
  @Suite("Text input composer")
  struct TextInputComposerTests {
    @Test func callbacksOutsideAKeyDownGoStraightToTheSink() {
      let sink = RecordingSink()
      let composer = TextInputComposer(sink: sink)
      composer.setMarkedText(
        "ni", selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(composer.hasMarkedText)
      #expect(composer.markedRange == NSRange(location: 0, length: 2))
      composer.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(!composer.hasMarkedText)
      composer.setMarkedText(
        "x", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      composer.unmarkText()
      composer.setMarkedText(
        "", selectedRange: NSRange(location: 0, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(sink.calls == ["compose ni 2", "commit 你", "compose x 1", "finish", "cancel"])
    }

    @Test func aKeyDownWithoutAnInputContextIsAPlainKey() throws {
      let sink = RecordingSink()
      let composer = TextInputComposer(sink: sink)
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
          context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
          keyCode: 0))
      composer.keyDown(event, context: nil)
      #expect(sink.calls == ["key 0"])
    }
  }
#endif
