import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Testing

@testable import OmnigentRemoteBrowser

/// The video and input path end to end with no UI: a live server, runner and browser host; the
/// core's real `RemoteBrowserDriver`; and hardware VideoToolbox decoding of every frame, whose
/// pixels are checked against the fixture page (`apps/apple/Tests/Fixtures/remote-browser`).
///
/// Runs when `OMNIGENT_E2E_SERVER_URL`, `OMNIGENT_E2E_REMOTE_SESSION_ID` (a session whose runner
/// has the remote browser on) and `OMNIGENT_E2E_REMOTE_PAGE_URL` (the fixture page over HTTP) are
/// set; skipped otherwise.
@MainActor
@Suite("Remote browser end to end", .enabled(if: LiveHost.current != nil), .serialized)
struct RemoteBrowserE2ETests {
  private let toggleBox = (x: 1050.0, y: 190.0)

  @Test func videoInputNavigationAndControl() async throws {
    let live = try #require(LiveHost.current)
    let core = try Self.core()
    defer { core.shutdown() }
    let phase = try await core.connect(serverUrl: live.server, expectedUserId: nil)
    guard case .connected = phase else { throw E2EError("not connected: \(phase)") }
    let connector = CoreRemoteBrowserConnector(core: core)
    let tab = try await connector.createTab(sessionID: live.sessionID, url: live.page, profile: nil)
    let session = E2ESession(core: core, sessionID: live.sessionID, tabID: tab.id)
    defer { session.driver.stop() }

    try await session.waitForPage()
    let hardware = try #require(session.listener.hardware)
    #expect(hardware.usingHardware, "\(hardware)")
    try await checkControl(session)
    let latencies = try await clickLatencies(session, clicks: 10)
    try await checkTyping(session)
    try await checkNavigation(session)
    try await checkRelease(session)
    let errors = session.listener.errors
    #expect(errors.isEmpty, "decode errors: \(errors)")
    print(
      "remote-browser-e2e: \(hardware); \(session.listener.frames.count) frames decoded;",
      "click to decoded frame \(Self.summary(latencies))")

    // Reattach: a new connection gets its own IDR of the same page.
    session.driver.stop()
    let again = E2ESession(core: core, sessionID: live.sessionID, tabID: tab.id)
    defer { again.driver.stop() }
    #expect(try await eventually(seconds: 20) { again.listener.frames.first?.keyframe == true })
    #expect(again.listener.frames.first.map { $0.box.isRed || $0.box.isGreen } == true)

    // Closing the tab over REST ends the attach.
    try await connector.closeTab(sessionID: live.sessionID, tabID: tab.id)
    #expect(try await eventually(seconds: 20) { again.listener.closed != nil })
  }

  /// Take gives this connection control without a keyframe; the page stays idle.
  private func checkControl(_ session: E2ESession) async throws {
    #expect(session.listener.snapshot?.control?.owner == .agent)
    let keyframes = session.listener.frames.filter(\.keyframe).count
    session.driver.takeControl()
    #expect(try await eventually(seconds: 10) { session.holdsControl })
    try await Task.sleep(for: .seconds(1))
    #expect(
      session.listener.frames.filter(\.keyframe).count == keyframes, "an IDR followed a take")
  }

  /// Clicks the toggle box and times each click to the first decoded frame showing its effect.
  private func clickLatencies(_ session: E2ESession, clicks: Int) async throws -> [Duration] {
    var latencies: [Duration] = []
    for _ in 0..<clicks {
      try await Task.sleep(for: .milliseconds(300))
      let wasRed = try #require(session.listener.frames.last).box.isRed
      let start = ContinuousClock.now
      try session.click(x: toggleBox.x, y: toggleBox.y)
      let frame = try await session.frame(after: start, seconds: 3) { $0.box.isRed != wasRed }
      latencies.append(frame.decodedAt - start)
    }
    return latencies
  }

  /// Clicks into the field and types: the title reports the text and the field shows it.
  private func checkTyping(_ session: E2ESession) async throws {
    #expect(session.listener.frames.last?.fieldHasText == false)
    try session.click(x: 300, y: 70)
    let start = ContinuousClock.now
    try session.type("hello", macKeyCodes: [4, 14, 37, 37, 31])
    #expect(try await eventually(seconds: 10) { session.title == "RB test page | typed:hello" })
    _ = try await session.frame(after: start, seconds: 5) { $0.fieldHasText }
    try session.click(x: 700, y: 70)
    #expect(try await eventually(seconds: 10) { session.title == "RB test page | clicked:1" })
  }

  /// Follows the link, then goes back with the driver.
  private func checkNavigation(_ session: E2ESession) async throws {
    let start = ContinuousClock.now
    try session.click(x: 150, y: 207)
    #expect(try await eventually(seconds: 10) { session.title == "RB second page" })
    let nav = try #require(session.listener.snapshot?.nav)
    #expect(nav.url.hasSuffix("/second.html"))
    #expect(nav.canGoBack)
    // The second page's lavender background replaces the first page's grey.
    _ = try await session.frame(after: start, seconds: 5) {
      $0.background.blue > $0.background.red + 10
    }
    let back = ContinuousClock.now
    try session.driver.nav(op: .back, url: nil)
    #expect(try await eventually(seconds: 10) { session.title.hasPrefix("RB test page") })
    #expect(session.listener.snapshot?.nav?.canGoForward == true)
    _ = try await session.frame(after: back, seconds: 5) { $0.box.isRed || $0.box.isGreen }
  }

  /// Hand back: the agent owns the tab again and clicks no longer reach the page.
  private func checkRelease(_ session: E2ESession) async throws {
    session.driver.releaseControl()
    #expect(
      try await eventually(seconds: 10) {
        let control = session.listener.snapshot?.control
        return control?.owner == .agent && control?.holder == .nobody
      })
    let wasRed = try #require(session.listener.frames.last).box.isRed
    let start = ContinuousClock.now
    try session.click(x: toggleBox.x, y: toggleBox.y)
    // The core drops holder-gated input and says so instead of sending it.
    #expect(
      try await eventually(seconds: 5) {
        session.listener.notices.contains { $0.hasSuffix("take control first") }
      })
    try await Task.sleep(for: .seconds(1))
    let later = session.listener.frames.filter { $0.decodedAt > start }
    #expect(later.allSatisfy { $0.box.isRed == wasRed }, "a click reached the page after Hand Back")
  }

  private static func core() throws -> ClientCore {
    try ClientCore(
      http: URLSessionHttpTransport(), streams: URLSessionEventStreamTransport(),
      sockets: URLSessionWebSocketTransport(), clock: SystemClock(), scheduler: TaskScheduler(),
      secureStore: InMemorySecureStore(), entropy: SystemEntropySource(),
      config: HostConfig(
        urlPolicy: .development, oidcRedirect: .loopback(path: "/oauth/callback"),
        databricks: nil))
  }

  private static func summary(_ latencies: [Duration]) -> String {
    let sorted = latencies.map { $0 / .milliseconds(1) }.sorted()
    guard let low = sorted.first, let high = sorted.last else { return "none" }
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
    let median = sorted[sorted.count / 2]
    return "ms p50 \(median.formatted(style)) p95 \(p95.formatted(style)) "
      + "min \(low.formatted(style)) max \(high.formatted(style)) (n=\(sorted.count))"
  }
}

/// One control attach through the core's driver, with a decoding listener.
@MainActor
struct E2ESession {
  let listener = E2EDecodingListener()
  let driver: RemoteBrowserDriver

  init(core: ClientCore, sessionID: String, tabID: String) {
    driver = core.remoteBrowserAttach(
      sessionId: sessionID, tabId: tabID, mode: .control, hostId: nil, listener: listener)
    driver.start()
  }

  var title: String { listener.snapshot?.nav?.title ?? "" }

  var holdsControl: Bool {
    let control = listener.snapshot?.control
    return control?.owner == .user && control?.holder == .this
  }

  /// Waits for the attach, the loaded page and a decoded frame showing it.
  func waitForPage() async throws {
    let attached = try await eventually(seconds: 30) {
      listener.snapshot?.connection == .attached(mode: .control)
    }
    guard attached else { throw E2EError("not attached: \(String(describing: listener.snapshot))") }
    guard try await eventually(seconds: 30, { title == "RB test page" }) else {
      throw E2EError("the page did not load; titles \(listener.titles)")
    }
    _ = try await frame(after: .now - .seconds(60), seconds: 20) {
      $0.box.isGreen && $0.background.red > 230 && $0.background.green > 230
    }
  }

  func click(x cssX: Double, y cssY: Double) throws {
    let held = RemoteModifiers.leftButton.rawValue
    for (kind, modifiers) in [(MouseKind.down, held), (MouseKind.up, 0)] {
      try driver.mouse(
        input: MouseInput(
          kind: kind, x: cssX, y: cssY, button: .left, clicks: 1, modifiers: modifiers, dx: 0, dy: 0
        ))
    }
  }

  /// Types lowercase letters as key down, char and key up, as the Mac view does.
  func type(_ text: String, macKeyCodes: [UInt16]) throws {
    for (character, code) in zip(text, macKeyCodes) {
      let key = String(character)
      let steps: [(KeyKind, String?)] = [(.rawKeyDown, nil), (.char, key), (.keyUp, nil)]
      for (kind, typed) in steps {
        try driver.key(
          input: KeyInput(
            kind: kind, macKeyCode: code, hidUsage: nil, code: nil, key: key, text: typed,
            modifiers: 0, repeat: false))
      }
    }
  }

  /// The first frame decoded after `start` that matches.
  func frame(
    after start: ContinuousClock.Instant, seconds: Int,
    where matches: (DecodedFrame) -> Bool
  ) async throws -> DecodedFrame {
    var found: DecodedFrame?
    _ = try await eventually(seconds: seconds, poll: .milliseconds(1)) {
      found = listener.frames.first { $0.decodedAt > start && matches($0) }
      return found != nil
    }
    guard let found else {
      throw E2EError("no matching frame; last \(String(describing: listener.frames.last))")
    }
    return found
  }
}

/// Polls `condition` until it holds or `seconds` pass.
@MainActor
func eventually(
  seconds: Int, poll: Duration = .milliseconds(10), _ condition: () -> Bool
) async throws -> Bool {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try await Task.sleep(for: poll)
  }
  return condition()
}

/// The live server, session and page from the environment.
nonisolated struct LiveHost: Sendable {
  let server: String
  let sessionID: String
  let page: String

  static let current: Self? = {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["OMNIGENT_E2E_SERVER_URL"],
      let sessionID = environment["OMNIGENT_E2E_REMOTE_SESSION_ID"],
      let page = environment["OMNIGENT_E2E_REMOTE_PAGE_URL"]
    else { return nil }
    return Self(server: server, sessionID: sessionID, page: page)
  }()
}
