#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentViewTesting

  /// A view that doesn't track the mouse: it records its mouse down and up. Its down can take
  /// long enough that its click's up comes due before the down returns, as on a busy machine.
  private final class PressRecorder: NSView {
    var events: [String] = []
    var downDuration: TimeInterval = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
      events.append("down")
      guard downDuration > 0 else { return }
      RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: downDuration))
    }

    override func mouseUp(with event: NSEvent) {
      events.append("up")
    }
  }

  private struct PressRecorderView: NSViewRepresentable {
    let recorder: PressRecorder

    func makeNSView(context: Context) -> PressRecorder { recorder }
    func updateNSView(_ view: PressRecorder, context: Context) {}
  }

  @MainActor
  @Suite("Offscreen presses", .serialized)
  struct OffscreenPressTests {
    @Test(
      "a click's up reaches a view that doesn't track, once, however long its down takes",
      arguments: [0, 0.1])
    func untrackedPress(downDuration: TimeInterval) throws {
      let recorder = PressRecorder()
      recorder.downDuration = downDuration
      let screen = OffscreenWindow(PressRecorderView(recorder: recorder), width: 200, height: 200)
      defer { screen.close() }
      try screen.click(CGPoint(x: 100, y: 100))
      #expect(recorder.events == ["down", "up"])
    }
  }
#endif
