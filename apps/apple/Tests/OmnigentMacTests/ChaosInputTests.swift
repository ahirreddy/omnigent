#if DEBUG
  import AppKit
  import SwiftUI
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

    @Test func aCoastingScrollSlowsToRestAfterTheGesture() {
      let steps = ChaosInput.scrollSteps(ticks: 2, momentum: true)
      #expect(steps.prefix(4).map(\.phase) == [1, 2, 2, 4])
      let coasting = steps.dropFirst(4)
      #expect(coasting.first?.momentum == 1)
      #expect(coasting.last?.momentum == 3)
      let scales = coasting.dropFirst().dropLast().map(\.scale)
      #expect(zip(scales, scales.dropFirst()).allSatisfy { $0 > $1 })
      #expect(ChaosInput.scrollSteps(ticks: 2, momentum: false).count == 4)
    }

    /// Counts what VoiceOver's actions reach.
    private final class Presses: NSObject {
      var count = 0
      @objc func press(_ sender: Any?) { count += 1 }
    }

    @Test func voiceOverActionsReachTheControl() {
      let presses = Presses()
      let button = NSButton(title: "Go", target: presses, action: #selector(Presses.press(_:)))
      button.setAccessibilityCustomActions([
        NSAccessibilityCustomAction(name: "Again") {
          presses.count += 10
          return true
        }
      ])
      let actions = ChaosAccessibility.actions(of: button)
      #expect(actions.map(\.name) == ["press", "custom \"Again\""])
      for action in actions { action.perform() }
      #expect(presses.count == 11)
      let slider = NSAccessibilityElement()
      slider.setAccessibilityRole(.slider)
      let sliderActions = Set(ChaosAccessibility.actions(of: slider).map(\.name))
      #expect(sliderActions.isSuperset(of: ["increment", "decrement"]))
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

    /// Clicks and VoiceOver actions find a SwiftUI window's controls in its own accessibility tree.
    @Test func aSwiftUIWindowsControlsAreFound() {
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: .titled,
        backing: .buffered, defer: false)
      window.contentView = NSHostingView(
        rootView: VStack {
          Button("Send") {}
          Toggle("Notify", isOn: .constant(true))
        }.frame(width: 300, height: 200))
      window.contentView?.layoutSubtreeIfNeeded()
      let names = ChaosTargets.controls(in: window).map(\.name)
      #expect(
        names.contains { $0.hasPrefix("AXButton") && $0.hasSuffix("Send") },
        "\(ChaosTargets.census(of: window))")
    }
  }
#endif
