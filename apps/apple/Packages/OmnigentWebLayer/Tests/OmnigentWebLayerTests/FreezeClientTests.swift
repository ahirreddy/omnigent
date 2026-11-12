import AppKit
import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

/// A clock the tests move by hand, in uptime nanoseconds.
@MainActor
final class FreezeClock {
  var nanos: UInt64 = 1_000_000_000_000

  func advance(seconds: Double) {
    nanos += UInt64(seconds * 1e9)
  }
}

/// The client's side of freeze diagnostics: input sent against frames received, on its own
/// clock, plus what the host reports.
@MainActor
@Suite("Freeze diagnostics on the client")
struct FreezeClientTests {
  private func fixture() -> (ProtocolFixture, FreezeClock) {
    let fixture = ProtocolFixture()
    let clock = FreezeClock()
    fixture.session.uptimeNanos = { clock.nanos }
    return (fixture, clock)
  }

  private func presented(_ fixture: ProtocolFixture) throws {
    try fixture.receive(.presented, WireEncoder().u64(.sequence, 1))
  }

  @Test("the detector reports input that got no frame, then the recovery")
  func detector() {
    var detector = FreezeDetector()
    let second: UInt64 = 1_000_000_000
    detector.noteInput(.move, sent: true, now: 10 * second)
    #expect(detector.tick(now: 20 * second) == .quiet, "pointer movement owes no frame")
    detector.noteInput(.click, sent: true, now: 20 * second)
    detector.noteInput(.key, sent: true, now: 21 * second)
    #expect(detector.isWaiting && detector.unansweredSinceNanos == 20 * second)
    #expect(detector.tick(now: 21 * second) == .quiet)
    #expect(detector.tick(now: 22 * second) == .stalled(milliseconds: 2000, line: 1))
    #expect(detector.tick(now: 23 * second) == .quiet)
    #expect(detector.tick(now: 30 * second) == .quiet, "nobody tried again")
    detector.noteInput(.wheel, sent: true, now: 31 * second)
    #expect(detector.tick(now: 50 * second) == .stalled(milliseconds: 30_000, line: 3))
    #expect(detector.waitingText == "click:1,wheel:1,key:1,move:1,text:0,drag:0,keyup:0")
    detector.noteFrame(now: 51 * second)
    #expect(!detector.isWaiting && detector.frames == 1)
    #expect(detector.tick(now: 52 * second) == .recovered(milliseconds: 32_000))
    #expect(detector.tick(now: 53 * second) == .quiet)
    #expect(detector.waitingText == "click:0,wheel:0,key:0,move:0,text:0,drag:0,keyup:0")
  }

  @Test("frames that arrive where nothing shows them are reported once")
  func unseenFrames() {
    var detector = FreezeDetector()
    let second: UInt64 = 1_000_000_000
    #expect(detector.tickUnseen(now: 1 * second, showable: false) == .quiet, "no frames at all")
    for tick in 2...5 {
      detector.noteFrame(now: UInt64(tick) * second)
      let expected: FreezeDetector.Verdict =
        tick == 4 ? .stalled(milliseconds: 2000, line: 1) : .quiet
      #expect(detector.tickUnseen(now: UInt64(tick) * second, showable: false) == expected)
    }
    detector.noteFrame(now: 30 * second)
    #expect(detector.tickUnseen(now: 30 * second, showable: false) == .quiet, "said once")
    detector.noteFrame(now: 31 * second)
    #expect(
      detector.tickUnseen(now: 31 * second, showable: true) == .recovered(milliseconds: 29_000))
    detector.noteFrame(now: 32 * second)
    #expect(detector.tickUnseen(now: 32 * second, showable: true) == .quiet)
  }

  @Test("a view whose layer is in no window says its frames are unseen")
  func unseenFramesLine() throws {
    let (fixture, clock) = fixture()
    let view = fixture.webView
    #expect(!view.layerHost.isShowable)
    for _ in 0..<3 {
      try presented(fixture)
      clock.advance(seconds: 1)
      fixture.session.freezeTick()
    }
    let line = try #require(fixture.session.freezeLines.last)
    #expect(line.hasPrefix("kind=client-frames-unseen view=\(view.id) unseen_ms=2000 "), "\(line)")
    #expect(line.contains("layer=mode:none,in_view:0,size:0x0 "), "\(line)")
  }

  @Test("an agent's page, which is never shown, is left out")
  func agentPagesAreNeverUnseen() throws {
    let (fixture, clock) = fixture()
    fixture.webView.rendersOffscreen = true
    for _ in 0..<4 {
      try presented(fixture)
      clock.advance(seconds: 1)
      fixture.session.freezeTick()
    }
    #expect(fixture.session.freezeLines.isEmpty)
  }

  @Test("input a view could not send is counted, and waits for nothing")
  func unsentInput() {
    var detector = FreezeDetector()
    detector.noteInput(.click, sent: false, now: 5)
    #expect(detector.inputsUnsent == 1 && detector.inputsSent == 0 && !detector.isWaiting)
  }

  @Test("a click with no frame after it is written down once, with what the app believes")
  func stallLine() throws {
    let (fixture, clock) = fixture()
    let view = fixture.webView
    view.url = URL(string: "https://example.com/secret/path?token=abc")
    try presented(fixture)
    view.renderer.forwardMouseEvent(try Offscreen.mouseEvent(.leftMouseDown), location: .zero)
    view.renderer.forwardKeyEvent(try Offscreen.keyEvent(.keyUp))
    clock.advance(seconds: 1)
    fixture.session.freezeTick()
    #expect(fixture.session.freezeLines.isEmpty)
    clock.advance(seconds: 1.1)
    fixture.session.freezeTick()
    let line = try #require(fixture.session.freezeLines.last)
    #expect(line.hasPrefix("kind=client-stall view=\(view.id) stalled_ms=2100 line=1 "))
    for part in [
      "waiting=click:1,wheel:0,key:0,move:0,text:0,drag:0,keyup:1", "sent=2", "unsent=0",
      "frames=1", "frame_age_ms=2100", "status=live", "told_host=visible:1,focused:0",
      "site=example.com", "surface=none", "view_report=none",
      "host=pid:0,running:0,cpu_pct:unknown",
      "ping_ms=0", "recv_queue=-1", "send_failures=0", "host_report=none",
    ] {
      #expect(line.contains(part), "\(part) in \(line)")
    }
    #expect(!line.contains("secret") && !line.contains("token"))
    fixture.session.freezeTick()
    #expect(fixture.session.freezeLines.count == 1, "one line per stage")

    clock.advance(seconds: 0.4)
    try presented(fixture)
    fixture.session.freezeTick()
    #expect(
      fixture.session.freezeLines.last
        == "kind=client-recovered view=\(view.id) stalled_ms=2500 frames=2")
  }

  @Test("input to a view that is not live is not sent, and the line says so")
  func inputThatIsNotSent() throws {
    let (fixture, clock) = fixture()
    fixture.webView.status = .creating
    fixture.webView.renderer.forwardMouseEvent(
      try Offscreen.mouseEvent(.leftMouseDown), location: .zero)
    #expect(fixture.sent.isEmpty && fixture.webView.freeze.inputsUnsent == 1)
    clock.advance(seconds: 3)
    fixture.session.freezeTick()
    #expect(fixture.session.freezeLines.isEmpty, "nothing was sent, so nothing is owed")
    #expect(fixture.webView.freezeStateText(now: clock.nanos).contains("unsent=1 "))
  }

  @Test("agent input, text and drags count too")
  func otherInput() throws {
    let (fixture, _) = fixture()
    let renderer = fixture.webView.renderer
    try renderer.agentClick(at: .zero)
    try renderer.agentScroll(at: .zero, deltaX: 0, deltaY: 3)
    try renderer.agentPress(.enter)
    try renderer.agentInsertText("typed text")
    renderer.commitText("more", replacementRange: nil)
    renderer.dragExited()
    let text = fixture.webView.freeze.waitingText
    #expect(text.hasPrefix("click:2,wheel:1,key:"), "\(text)")
    #expect(text.contains("move:1,text:2,drag:1"), "\(text)")
    #expect(!fixture.webView.freezeStateText(now: 0).contains("typed"))
  }

  @Test("a tick that ran late judges nothing until queued frames are read")
  func lateTick() throws {
    let (fixture, clock) = fixture()
    fixture.session.freezeTick()
    fixture.webView.renderer.forwardMouseEvent(
      try Offscreen.mouseEvent(.leftMouseDown), location: .zero)
    clock.advance(seconds: 4)
    fixture.session.freezeTick()
    let late = try #require(fixture.session.freezeLines.first)
    #expect(late.hasPrefix("kind=client-timer-late late_ms=4000 host=pid:0,"), "\(late)")
    #expect(fixture.session.freezeLines.count == 1)
    clock.advance(seconds: 1)
    fixture.session.freezeTick()
    #expect(fixture.session.freezeLines.last?.hasPrefix("kind=client-stall ") == true)
  }

  @Test("the host's reports are logged and remembered")
  func hostReports() throws {
    let (fixture, clock) = fixture()
    let view = fixture.webView
    try fixture.receive(
      .healthReport,
      WireEncoder().u64(.healthKind, OWLHealthKind.viewStall.rawValue)
        .u64(.elapsedMilliseconds, 2100).string(
          .text, "kind=view-stall view=\(view.id) reason=input"))
    #expect(
      fixture.session.freezeLines == ["from=host kind=view-stall view=\(view.id) reason=input"])
    #expect(view.lastHostReport?.kindName == "view-stall")
    #expect(view.lastHostReport?.milliseconds == 2100)

    try fixture.receive(
      .healthReport, target: 0,
      WireEncoder().u64(.healthKind, OWLHealthKind.hostStall.rawValue)
        .string(.text, "kind=host-stall stalled_ms=1200"))
    #expect(fixture.session.freeze.lastHostReport?.kindName == "host-stall")
    clock.advance(seconds: 0.25)
    #expect(view.freezeStateText(now: clock.nanos).contains("view_report=view-stall,age_ms:250"))
    #expect(
      fixture.session.freezeStateText(now: clock.nanos)
        .hasSuffix("host_report=host-stall,age_ms:250"))
    #expect(fixture.session.lastProtocolError == nil)
  }

  @Test("a report without text, or of an unknown kind, is handled")
  func hostileReports() throws {
    let (fixture, _) = fixture()
    try fixture.receive(.healthReport, WireEncoder().u64(.healthKind, 1))
    #expect(fixture.session.freezeLines.isEmpty)
    #expect(fixture.session.lastProtocolError != nil)
    try fixture.receive(
      .healthReport,
      WireEncoder().u64(.healthKind, 99).string(.text, String(repeating: "x", count: 5000)))
    #expect(fixture.webView.lastHostReport?.kindName == "kind-99")
    #expect(fixture.session.freezeLines.last?.count == "from=host ".count + 1000)
    #expect(HostHealthReport(kind: 0, milliseconds: 0, receivedNanos: 0).kindName == "kind-0")
  }
}

/// What the app writes down besides stalls: what it told the host, and whether the page can
/// be typed into.
@MainActor
@Suite("Freeze transitions on the client")
struct FreezeTransitionTests {
  private func fixture() -> (ProtocolFixture, FreezeClock) {
    let fixture = ProtocolFixture()
    let clock = FreezeClock()
    fixture.session.uptimeNanos = { clock.nanos }
    return (fixture, clock)
  }

  @Test func healthReportIsTheNewestKindTheClientKnows() throws {
    let known = IncomingMessage(
      kindValue: 131, request: 0, target: 0, protocolMajor: 1, fields: try WireDecoder([]),
      port: nil)
    let unknown = IncomingMessage(
      kindValue: 132, request: 0, target: 0, protocolMajor: 1, fields: try WireDecoder([]),
      port: nil)
    #expect(known.kind == .healthReport && unknown.kind == nil)
  }

  @Test("what the app tells the host about visibility and focus is logged")
  func transitions() {
    let (fixture, _) = fixture()
    let view = fixture.webView
    view.setVisible(false)
    view.setVisible(false)
    view.setFocused(true)
    view.setFocused(false)
    view.setVisible(true)
    #expect(
      fixture.session.freezeLines == [
        "kind=client-hidden view=\(view.id) status=live surface=none",
        "kind=client-focused view=\(view.id) status=live surface=none",
        "kind=client-blurred view=\(view.id) status=live surface=none",
        "kind=client-shown view=\(view.id) status=live surface=none",
      ])
  }

  @Test("only the newest lines are kept")
  func lineLimit() {
    let (fixture, _) = fixture()
    for index in 0..<(Session.freezeLineLimit + 5) {
      fixture.session.logFreeze("kind=test index=\(index)")
    }
    #expect(fixture.session.freezeLines.count == Session.freezeLineLimit)
    #expect(fixture.session.freezeLines.first == "kind=test index=5")
  }

  @Test("the surface says whether typing can reach the page")
  func surfaceState() throws {
    let hosted = HostedSurface()
    let other = NSTextField(frame: .zero)
    hosted.surface.addSubview(other)
    #expect(hosted.surface.surfaceState.inWindow)
    #expect(!hosted.surface.surfaceState.isFirstResponder)
    hosted.surface.takeKeyboard()
    #expect(hosted.surface.surfaceState.isFirstResponder)
    #expect(hosted.surface.surfaceState.firstResponder == "WebSurfaceView")
    #expect(hosted.fixture.webView.surfaceState?().isFirstResponder == true)
    let text = hosted.fixture.webView.freezeStateText(now: 0)
    #expect(text.contains("first_responder:1,keyboard_at:WebSurfaceView"), "\(text)")
    #expect(text.contains("told_host=visible:0,focused:1"), "\(text)")
    hosted.window.makeFirstResponder(nil)
    #expect(!hosted.surface.surfaceState.isFirstResponder)
    #expect(WebSurfaceView(webView: hosted.fixture.webView).surfaceState == WebSurfaceState())
  }

  @Test("a window that refuses the page the keyboard is in the log")
  func keyboardRefused() {
    let hosted = HostedSurface(window: RefusingWindow.make())
    hosted.surface.takeKeyboard()
    let line = hosted.fixture.session.freezeLines.last ?? ""
    #expect(line.hasPrefix("kind=client-keyboard-refused view=\(hosted.fixture.webView.id) "))
    #expect(line.contains("first_responder:0"))
  }

  @Test("the host's CPU time comes from the kernel")
  func processCPU() {
    #expect((Session.processCPUNanos(getpid()) ?? 0) > 0)
    #expect(Session.processCPUNanos(-1) == nil)
  }
}

/// A window that gives the keyboard to nobody.
private final class RefusingWindow: NSWindow {
  static func make() -> RefusingWindow {
    RefusingWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
      backing: .buffered, defer: false)
  }

  override func makeFirstResponder(_ responder: NSResponder?) -> Bool { false }
}
