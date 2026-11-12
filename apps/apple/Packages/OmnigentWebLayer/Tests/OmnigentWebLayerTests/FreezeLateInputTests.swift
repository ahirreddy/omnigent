import AppKit
import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

/// Input that waited in the app before the view got it: the app's main thread was busy, and the
/// page, which looked frozen meanwhile, was never asked anything.
@MainActor
@Suite("Late input on the client")
struct FreezeLateInputTests {
  private static let second: UInt64 = 1_000_000_000

  @Test("input is late from 300 ms, and later ones are counted into the next line")
  func detector() {
    var detector = FreezeDetector()
    let now = 100 * Self.second
    #expect(detector.noteDelivery(happened: 0, now: now) == nil, "an event without a time")
    #expect(detector.noteDelivery(happened: now + 5, now: now) == nil, "a time yet to come")
    #expect(detector.noteDelivery(happened: now - 299_000_000, now: now) == nil)
    #expect(
      detector.noteDelivery(happened: now - 300_000_000, now: now)
        == FreezeDetector.LateInput(milliseconds: 300, count: 1, worstMilliseconds: 300))
    // Two more within the quiet time say nothing by themselves.
    #expect(detector.noteDelivery(happened: now - Self.second, now: now + Self.second) == nil)
    #expect(detector.noteDelivery(happened: now, now: now + 2 * Self.second) == nil)
    #expect(
      detector.noteDelivery(happened: now + 5 * Self.second, now: now + 6 * Self.second)
        == FreezeDetector.LateInput(milliseconds: 1000, count: 3, worstMilliseconds: 2000))
  }

  @Test("a click and a key the app delivered late are written down, with how late")
  func line() throws {
    let fixture = ProtocolFixture()
    let clock = FreezeClock()
    fixture.session.uptimeNanos = { clock.nanos }
    let view = fixture.webView
    let now = Double(clock.nanos) / 1e9
    view.renderer.forwardMouseEvent(try Self.click(at: now - 0.1), location: .zero)
    view.renderer.forwardMouseEvent(try Offscreen.mouseEvent(.leftMouseDown), location: .zero)
    #expect(fixture.session.freezeLines.isEmpty, "on time, or without a time")

    view.renderer.forwardMouseEvent(try Self.click(at: now - 1.5), location: .zero)
    let line = try #require(fixture.session.freezeLines.last)
    let start = "kind=client-input-late view=\(view.id) "
    #expect(line.hasPrefix(start + "late_ms=1500 late_inputs=1 worst_ms=1500 "))
    #expect(line.contains(" recv_queue="))
    #expect(fixture.sent.filter { $0.kind == .inputMouse }.count == 3, "late input is still sent")

    let key = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: now - 2, windowNumber: 0,
        context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
        keyCode: 0))
    clock.advance(seconds: 6)
    view.renderer.forwardKeyEvent(key)
    let later = try #require(fixture.session.freezeLines.last)
    #expect(later.hasPrefix(start + "late_ms=8000 late_inputs=1 worst_ms=8000 "))
  }

  private static func click(at seconds: Double) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: seconds,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  }
}
