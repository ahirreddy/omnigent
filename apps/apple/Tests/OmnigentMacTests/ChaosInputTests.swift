#if DEBUG
  import AppKit
  import Testing

  #if OMNIGENT_CHROMIUM
    @testable import OmnigentMac
  #else
    @testable import OmnigentMacAppStore
  #endif

  /// The chaos driver's input-method typing leaves what a person's would.
  @MainActor
  struct ChaosInputTests {
    /// A text view, first responder in a window that is never ordered front.
    private static func textView() throws -> (NSWindow, NSTextView) {
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 300, height: 100), styleMask: .borderless,
        backing: .buffered, defer: true)
      let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
      window.contentView?.addSubview(view)
      #expect(window.makeFirstResponder(view))
      return (window, view)
    }

    /// Waits for the main queue to run what composing scheduled.
    private static func settle(_ view: NSTextView) async throws {
      try await Task.sleep(for: .milliseconds(100))
      for _ in 0..<100 where view.hasMarkedText() {
        try await Task.sleep(for: .milliseconds(20))
      }
    }

    @Test func composedTextIsCommitted() async throws {
      let (window, view) = try Self.textView()
      #expect(ChaosInput.compose("かんじ", abandons: false, pause: 0, in: window))
      try await Self.settle(view)

      #expect(view.string == "かんじ")
      #expect(!view.hasMarkedText())
    }

    @Test func abandonedTextIsDropped() async throws {
      let (window, view) = try Self.textView()
      view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(ChaosInput.compose("한국어", abandons: true, pause: 0, in: window))
      try await Self.settle(view)

      #expect(view.string == "a")
      #expect(!view.hasMarkedText())
    }

    @Test func aResponderWithoutTextInputTakesNone() throws {
      let (window, _) = try Self.textView()
      #expect(window.makeFirstResponder(nil))
      #expect(!ChaosInput.compose("かんじ", abandons: false, pause: 0, in: window))
    }
  }
#endif
