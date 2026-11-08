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

    @Test func aSweepVisitsEveryHeightBetweenItsEnds() {
      #expect(ChaosWindows.sweepHeights(from: 300, to: 400, steps: 4) == [300, 325, 350, 375, 400])
      #expect(ChaosWindows.sweepHeights(from: 400, to: 301, steps: 2) == [400, 351, 301])
      #expect(ChaosWindows.sweepHeights(from: 300, to: 400, steps: 0) == [300, 400])
    }

    @Test func theSmallestSizeKeepsTheWindowOnScreen() {
      let window = NSWindow(
        contentRect: CGRect(x: 40, y: 500, width: 300, height: 400),
        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
      window.minSize = .zero
      #expect(ChaosWindows.smallestSize(of: window).height > 40)
      window.contentMinSize = CGSize(width: 260, height: 200)
      let smallest = ChaosWindows.smallestSize(of: window)
      #expect(smallest.width >= 260)
      #expect(smallest.height > 200)
    }

    @Test func aSweepKeepsTheTopEdgeAndEndsAtTheLastHeight() async throws {
      let window = NSWindow(
        contentRect: CGRect(x: 40, y: 500, width: 300, height: 400), styleMask: .borderless,
        backing: .buffered, defer: true)
      let top = window.frame.maxY
      ChaosWindows.sweep(window, width: 320, heights: [380, 350, 330], pause: 0.01)
      try await Task.sleep(for: .milliseconds(300))

      #expect(window.frame.size == CGSize(width: 320, height: 330))
      #expect(window.frame.maxY == top)
    }
  }
#endif
