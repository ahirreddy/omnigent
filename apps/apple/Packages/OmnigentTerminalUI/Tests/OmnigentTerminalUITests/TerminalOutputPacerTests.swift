import Foundation
import Testing

@testable import OmnigentTerminalUI

/// A surface's frames as the pacer reads them, set by each test.
@MainActor
private final class FakeFrames {
  var updated = 0
  var shown = 0
  var isInWindow = true
  var fed: [String] = []
  var events: [String] = []

  func pacer() -> TerminalOutputPacer {
    let probe = TerminalFrameProbe(
      updatedFrames: { self.updated }, shownFrames: { self.shown },
      isInWindow: { self.isInWindow })
    return TerminalOutputPacer(
      probe: probe,
      feed: { bytes in
        self.fed.append(String(bytes: bytes, encoding: .utf8) ?? "<not UTF-8>")
        self.events.append("feed")
      },
      commit: { self.events.append("commit") })
  }

  /// libghostty's renderer takes the screen for its next frame.
  func takeTheScreen() { updated += 1 }

  /// The main thread puts the drawn frame on the layer.
  func showTheFrame() { shown += 1 }
}

private let escape = "\u{1B}"

@MainActor
@Suite("Terminal output waits for the frame in flight to reach the layer")
struct TerminalOutputPacerTests {
  @Test("out of a window, output is parsed as it comes")
  func outOfAWindow() {
    let frames = FakeFrames()
    frames.isInWindow = false
    let pacer = frames.pacer()
    pacer.submit(Array("a".utf8))
    frames.takeTheScreen()
    pacer.submit(Array("b".utf8))
    #expect(frames.fed == ["a", "b"])
    #expect(!frames.events.contains("commit"), "nothing shown to commit")
  }

  @Test("output the renderer has not taken yet goes into its next frame")
  func beforeTheRendererTakesIt() {
    let frames = FakeFrames()
    let pacer = frames.pacer()
    pacer.submit(Array("a".utf8))
    pacer.submit(Array("b".utf8))
    #expect(frames.fed == ["a", "b"])
    #expect(pacer.pending.isEmpty)
    #expect(frames.events == ["feed", "feed"], "nothing new on the layer to commit")
  }

  @Test("a frame not yet on the layer holds output, in order, until the layer shows it")
  func holdsUntilShown() async throws {
    let frames = FakeFrames()
    let pacer = frames.pacer()
    pacer.submit(Array("a".utf8))
    frames.takeTheScreen()
    pacer.submit(Array("b".utf8))
    pacer.submit(Array("c".utf8))
    #expect(frames.fed == ["a"])
    #expect(pacer.pending == Array("bc".utf8))
    try await Task.sleep(for: .milliseconds(10))
    #expect(frames.fed == ["a"], "held while the frame is not on the layer")

    frames.showTheFrame()
    #expect(await eventually { frames.fed == ["a", "bc"] })
    // The shown frame is committed before the next output can start another frame.
    #expect(frames.events == ["feed", "commit", "feed"])
  }

  @Test("a frame the layer never shows holds output no longer than the limit")
  func frameNeverShown() async {
    let frames = FakeFrames()
    let pacer = frames.pacer()
    pacer.submit(Array("a".utf8))
    frames.takeTheScreen()
    let start = ContinuousClock.now
    pacer.submit(Array("b".utf8))
    #expect(await eventually { frames.fed == ["a", "b"] })
    #expect(ContinuousClock.now - start >= TerminalOutputPacer.longestHold)
  }

  @Test("the rest of a synchronized update is not held: no frame is drawn until it ends")
  func synchronizedUpdate() {
    let frames = FakeFrames()
    let pacer = frames.pacer()
    pacer.submit(Array("\(escape)[?2026hfirst half".utf8))
    frames.takeTheScreen()
    pacer.submit(Array(" second half\(escape)[?2026l".utf8))
    #expect(frames.fed.count == 2, "the update's two halves are parsed together")
    frames.takeTheScreen()
    pacer.submit(Array("after".utf8))
    #expect(frames.fed.count == 2, "the finished update's frame is in flight")
  }

  @Test("synchronized output follows its last mode change, and a reset ends it")
  func synchronizedOutputState() {
    func after(_ text: String, from isOn: Bool = false) -> Bool {
      TerminalOutputPacer.leavesSynchronizedOutputOn(Array(text.utf8), from: isOn)
    }
    #expect(after("\(escape)[?2026h"))
    #expect(!after("\(escape)[?2026h frame \(escape)[?2026l"))
    #expect(after("\(escape)[?2026l\(escape)[?2026h"))
    #expect(after("plain text", from: true))
    #expect(!after("\(escape)c", from: true))
    #expect(!after("\(escape)[?2025h\(escape)[?20"), "another mode, and one cut short")
    #expect(after("\(escape)", from: true))
  }

  @Test("a surface that leaves its window parses what it held")
  func leavesItsWindow() async throws {
    let frames = FakeFrames()
    let pacer = frames.pacer()
    pacer.submit(Array("a".utf8))
    frames.takeTheScreen()
    pacer.submit(Array("b".utf8))
    frames.isInWindow = false
    // Well inside the limit, which would release it anyway.
    try await Task.sleep(for: .milliseconds(10))
    #expect(frames.fed == ["a", "b"])
  }

  @Test("a pacer that goes away while it holds output stops waiting")
  func releasedWhileHolding() async throws {
    let frames = FakeFrames()
    var pacer: TerminalOutputPacer? = frames.pacer()
    pacer?.submit(Array("a".utf8))
    frames.takeTheScreen()
    pacer?.submit(Array("b".utf8))
    weak var released: TerminalOutputPacer?
    released = pacer
    pacer = nil
    try await Task.sleep(for: TerminalOutputPacer.longestHold * 2)
    #expect(released == nil)
    #expect(frames.fed == ["a"], "nothing is parsed into a surface that is gone")
  }
}
