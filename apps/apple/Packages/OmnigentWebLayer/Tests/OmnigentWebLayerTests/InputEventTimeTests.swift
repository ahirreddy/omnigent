import AppKit
import Foundation
import OWLProtocol
import OWLProtocolCallers
import Testing

@testable import OmnigentWebLayer

/// The time an input happened: a user's event sends its own, agent input sends none, and the
/// host resolves what it stamps with the rule in owl_protocol.h.
@MainActor
@Suite("Input event times")
struct InputEventTimeTests {
  private func mouse(
    _ type: NSEvent.EventType, at time: TimeInterval, window: NSWindow? = nil
  ) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: CGPoint(x: 5, y: 5), modifierFlags: [], timestamp: time,
        windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 1))
  }

  private func key(
    _ type: NSEvent.EventType, at time: TimeInterval, characters: String = "a",
    flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0, window: NSWindow? = nil
  ) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: time,
        windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
  }

  @Test func theFieldAndVersionAreStable() {
    #expect(OWL_PROTOCOL_MINOR_EVENT_TIME == 4)
    #expect(OWL_PROTOCOL_MINOR >= OWL_PROTOCOL_MINOR_EVENT_TIME)
    #expect(OWLField.eventTime.rawValue == 128)
    #expect(OWLHostErrorCode.inputFailed.rawValue == 11)
  }

  @Test("a user's pointer event sends the time it happened")
  func pointerEvents() throws {
    let fixture = ProtocolFixture()
    let renderer = fixture.webView.renderer
    let types: [NSEvent.EventType] = [
      .leftMouseDown, .leftMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDown, .otherMouseUp,
    ]
    for (offset, type) in types.enumerated() {
      let time = 1_000.25 + Double(offset)
      renderer.forwardMouseEvent(try mouse(type, at: time), location: .zero)
      #expect(fixture.sent.last?.kind == .inputMouse)
      #expect(fixture.sent.last?.fields.double(.eventTime) == time)
    }
    #expect(fixture.sent.count == types.count)
  }

  @Test("a scroll sends the time of its event")
  func scrolls() throws {
    let fixture = ProtocolFixture()
    let wheel = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 3, wheel2: 0, wheel3: 0)
    )
    wheel.timestamp = 3_000_000_000_000
    let event = try #require(NSEvent(cgEvent: wheel))
    fixture.webView.renderer.forwardMouseEvent(event, location: .zero)
    let sent = try #require(fixture.last(.inputMouse))
    #expect(sent.u64(.mouseKind) == OWLMouseKind.wheel.rawValue)
    // AppKit converts the Core Graphics time; whatever it reports is what goes out.
    #expect(sent.double(.eventTime) == (event.timestamp > 0 ? event.timestamp : nil))
  }

  @Test("every key message of one key event sends that event's time")
  func keyEvents() throws {
    let fixture = ProtocolFixture()
    let renderer = fixture.webView.renderer
    renderer.forwardKeyEvent(try key(.keyDown, at: 2_000.5))
    #expect(fixture.sent.map { $0.fields.u64(.keyKind) } == [0, 3])
    #expect(fixture.sent.allSatisfy { $0.fields.double(.eventTime) == 2_000.5 })
    renderer.forwardKeyEvent(try key(.keyUp, at: 2_000.75))
    #expect(fixture.sent.last?.fields.double(.eventTime) == 2_000.75)
    renderer.forwardKeyEvent(
      try key(.flagsChanged, at: 2_001, characters: "", flags: .shift, keyCode: 56))
    #expect(fixture.sent.last?.fields.double(.eventTime) == 2_001)
    #expect(fixture.sent.count == 4)
  }

  @Test("events the view receives keep their time on the way to the page")
  func throughTheView() throws {
    let host = HostedSurface()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    surface.mouseDown(with: try mouse(.leftMouseDown, at: 50.5, window: window))
    #expect(fixture.last(.inputMouse)?.double(.eventTime) == 50.5)
    surface.mouseUp(with: try mouse(.leftMouseUp, at: 50.625, window: window))
    #expect(fixture.last(.inputMouse)?.double(.eventTime) == 50.625)
    surface.keyDown(with: try key(.keyDown, at: 51.5, flags: .command, window: window))
    #expect(fixture.last(.inputKey)?.double(.eventTime) == 51.5)
    surface.keyUp(with: try key(.keyUp, at: 51.75, window: window))
    #expect(fixture.last(.inputKey)?.double(.eventTime) == 51.75)
    window.contentView = nil
  }

  @Test("an event built without a real time sends none")
  func eventsWithoutATime() throws {
    let fixture = ProtocolFixture()
    let renderer = fixture.webView.renderer
    renderer.forwardMouseEvent(try mouse(.leftMouseDown, at: 0), location: .zero)
    renderer.forwardKeyEvent(try key(.keyDown, at: 0))
    #expect(fixture.sent.count == 3)
    #expect(fixture.sent.allSatisfy { $0.fields.double(.eventTime) == nil })
    for time in [nil, 0, -1, -Double.infinity, Double.infinity, Double.nan] as [TimeInterval?] {
      #expect(WireEncoder().eventTime(time).bytes.isEmpty, "\(String(describing: time))")
    }
    let kept = try WireDecoder(WireEncoder().eventTime(0.001).bytes)
    #expect(kept.double(.eventTime) == 0.001)
  }

  @Test("agent input sends no time; the host stamps it")
  func agentInput() throws {
    let fixture = ProtocolFixture()
    let renderer = fixture.webView.renderer
    try renderer.agentClick(at: CGPoint(x: 3, y: 4))
    try renderer.agentMove(to: .zero)
    try renderer.agentScroll(at: .zero, deltaX: 0, deltaY: -10)
    try renderer.agentPress(.enter)
    try renderer.agentType("ab")
    try renderer.agentInsertText("text")
    let kinds = Set(fixture.sent.map(\.kind.rawValue))
    let expected: Set = [
      OWLMessageKind.inputMouse.rawValue, OWLMessageKind.inputKey.rawValue,
      OWLMessageKind.imeCommitText.rawValue,
    ]
    #expect(kinds == expected)
    #expect(fixture.sent.allSatisfy { $0.fields.double(.eventTime) == nil })
  }

  @Test("the host uses a real past time and its own clock for anything else")
  func resolvedTime() {
    let now = 500.0
    #expect(owl_input_event_time_in_c(499.5, now, 0) == 499.5)
    #expect(owl_input_event_time_in_c(now, now, 0) == now)
    // Absent, the future, and values that are not times.
    for unusable in [0, 500.001, 9e18, -1, -Double.infinity, Double.infinity, Double.nan] {
      #expect(owl_input_event_time_in_c(unusable, now, 0) == now, "\(unusable)")
    }
    // The first input of a host that has seen no event yet is stamped, not left at 0.
    #expect(owl_input_event_time_in_c(0, 0.25, 0) == 0.25)
  }

  @Test("a view's input times never run backwards")
  func timesNeverRunBackwards() {
    // An event older than what the view already got is moved up to it.
    #expect(owl_input_event_time_in_c(100, 500, 400) == 400)
    #expect(owl_input_event_time_in_c(0, 500, 600) == 600)
    #expect(owl_input_event_time_in_c(450, 500, 400) == 450)

    // Agent input (0) between user events, a late event, a bogus one, and a page commit.
    let inputs: [(eventTime: Double, now: Double)] = [
      (0, 10), (9.5, 10.5), (10.25, 10.75), (0, 11), (10.9, 11.5), (.nan, 11.5), (99, 12),
      (11.75, 12.5),
    ]
    var earliest = 0.0
    var stamped: [Double] = []
    for (index, input) in inputs.enumerated() {
      if index == 4 { earliest = max(earliest, 11.25) }
      earliest = owl_input_event_time_in_c(input.eventTime, input.now, earliest)
      stamped.append(earliest)
    }
    #expect(stamped == [10, 10, 10.25, 11, 11.25, 11.5, 12, 12])
    #expect(stamped.allSatisfy { $0 > 0 })
  }
}
