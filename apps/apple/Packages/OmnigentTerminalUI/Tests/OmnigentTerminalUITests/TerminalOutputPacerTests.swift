import Foundation
import Testing

@testable import OmnigentTerminalUI

/// A surface's frames as the pacer reads them, set by each test.
@MainActor
private final class FakeFrames {
  var drawn = 0
  var shown = NSObject()
  var isInWindow = true
  var fed: [String] = []
  var events: [String] = []

  func pacer() -> TerminalOutputPacer {
    let probe = TerminalFrameProbe(
      drawnFrames: { self.drawn }, shownFrame: { ObjectIdentifier(self.shown) },
      isInWindow: { self.isInWindow })
    return TerminalOutputPacer(
      probe: probe,
      feed: { bytes in
        self.fed.append(String(bytes: bytes, encoding: .utf8) ?? "<not UTF-8>")
        self.events.append("feed")
      },
      commit: { self.events.append("commit") })
  }

  /// libghostty draws a frame from what it was fed.
  func draw() { drawn += 1 }

  /// The main thread puts the drawn frame on the layer.
  func showDrawnFrame() { shown = NSObject() }
}

@MainActor
@Suite("Terminal output waits for the frame in flight to reach the layer")
struct TerminalOutputPacerTests {
  @Test("out of a window, output is parsed as it comes")
  func outOfAWindow() {
    let frames = FakeFrames()
    frames.isInWindow = false
    let pacer = frames.pacer()
    pacer.submit(Array("a".utf8))
    frames.draw()
    pacer.submit(Array("b".utf8))
    #expect(frames.fed == ["a", "b"])
    #expect(!frames.events.contains("commit"), "nothing shown to commit")
  }

  @Test("output before the next frame is drawn goes into that frame")
  func beforeTheNextDraw() {
    let frames = FakeFrames()
    let pacer = frames.pacer()
    pacer.submit(Array("a".utf8))
    pacer.submit(Array("b".utf8))
    #expect(frames.fed == ["a", "b"])
    #expect(pacer.pending.isEmpty)
    #expect(frames.events == ["commit", "feed", "feed"], "nothing new on the layer to commit")
  }

  @Test("a frame drawn but not on the layer holds output, in order, until the layer shows it")
  func holdsUntilShown() async throws {
    let frames = FakeFrames()
    let pacer = frames.pacer()
    pacer.submit(Array("a".utf8))
    frames.draw()
    pacer.submit(Array("b".utf8))
    pacer.submit(Array("c".utf8))
    #expect(frames.fed == ["a"])
    #expect(pacer.pending == Array("bc".utf8))
    try await Task.sleep(for: .milliseconds(10))
    #expect(frames.fed == ["a"], "held while the frame is not on the layer")

    frames.showDrawnFrame()
    #expect(await eventually { frames.fed == ["a", "bc"] })
    // The shown frame is committed before the next output can start another frame.
    #expect(frames.events.suffix(2) == ["commit", "feed"])
  }

  @Test("a frame the layer never shows holds output no longer than the limit")
  func frameNeverShown() async {
    let frames = FakeFrames()
    let pacer = frames.pacer()
    pacer.submit(Array("a".utf8))
    frames.draw()
    let start = ContinuousClock.now
    pacer.submit(Array("b".utf8))
    #expect(await eventually { frames.fed == ["a", "b"] })
    #expect(ContinuousClock.now - start >= TerminalOutputPacer.longestHold)
  }

  @Test("a surface that leaves its window parses what it held")
  func leavesItsWindow() async {
    let frames = FakeFrames()
    let pacer = frames.pacer()
    pacer.submit(Array("a".utf8))
    frames.draw()
    pacer.submit(Array("b".utf8))
    frames.isInWindow = false
    #expect(await eventually(timeout: .milliseconds(40)) { frames.fed == ["a", "b"] })
  }

  @Test("a pacer that goes away while it holds output stops waiting")
  func releasedWhileHolding() async throws {
    let frames = FakeFrames()
    var pacer: TerminalOutputPacer? = frames.pacer()
    pacer?.submit(Array("a".utf8))
    frames.draw()
    pacer?.submit(Array("b".utf8))
    weak var released: TerminalOutputPacer?
    released = pacer
    pacer = nil
    try await Task.sleep(for: TerminalOutputPacer.longestHold * 2)
    #expect(released == nil)
    #expect(frames.fed == ["a"], "nothing is parsed into a surface that is gone")
  }
}
