import Testing

@testable import OmnigentDesktop

// Decision table ported from web/electron/test/deepLink.test.js ("chooseDeepLinkStrategy").
// Electron's "mid-auth, off-origin" window maps to a bound window that is not ready yet.

@Suite("Deep link window routing")
struct DeepLinkRoutingTests {
  let origin: ServerOrigin
  let other: ServerOrigin

  init() throws {
    origin = try ServerOrigin(serialized: "https://my-workspace.cloud.databricks.com")
    other = try ServerOrigin(serialized: "https://other.example.com")
  }

  private func window(_ id: Int, _ origin: ServerOrigin?, ready: Bool = true)
    -> WindowRoutingSnapshot<Int>
  {
    WindowRoutingSnapshot(id: id, origin: origin, isReady: ready)
  }

  private func decide(
    _ windows: [WindowRoutingSnapshot<Int>], known: Set<ServerOrigin>, focused: Int? = nil
  ) -> DeepLinkStrategy<Int> {
    DeepLinkRouting.strategy(
      target: origin, windows: windows, knownOrigins: known, focused: focused)
  }

  @Test("navigates a ready window on the server in place")
  func readyWindow() {
    #expect(decide([window(0, origin)], known: [origin]) == .navigate(0))
  }

  @Test("waits for a bound window that is still connecting")
  func connectingWindow() {
    #expect(
      decide([window(0, origin, ready: false)], known: [origin]) == .navigateWhenReady(0))
  }

  @Test("prefers the focused window among several ready ones")
  func focusedAmongReady() {
    #expect(
      decide([window(0, origin), window(1, origin)], known: [origin], focused: 1)
        == .navigate(1))
  }

  @Test("prefers a ready window over a focused one that is connecting")
  func readyBeatsFocusedConnecting() {
    #expect(
      decide(
        [window(0, origin), window(1, origin, ready: false)], known: [origin],
        focused: 1) == .navigate(0))
  }

  @Test("falls back to the first bound window when none is ready")
  func firstConnecting() {
    #expect(
      decide(
        [window(0, origin, ready: false), window(1, origin, ready: false)],
        known: [origin]) == .navigateWhenReady(0))
  }

  @Test("prefers the focused connecting window when none is ready")
  func focusedConnecting() {
    #expect(
      decide(
        [window(0, origin, ready: false), window(1, origin, ready: false)],
        known: [origin], focused: 1) == .navigateWhenReady(1))
  }

  @Test("opens a new window for a known server with no window")
  func knownServer() {
    #expect(decide([window(0, other)], known: [origin, other]) == .openKnownServer)
  }

  @Test("requires consent for a never-connected server")
  func unknownServer() {
    #expect(decide([], known: [other]) == .requireConsent)
  }

  @Test("ignores connect-screen windows")
  func connectScreenWindows() {
    #expect(decide([window(0, nil, ready: false)], known: []) == .requireConsent)
  }

  @Test("routes to a bound window even when the server is not in the known list")
  func boundButUnknown() {
    #expect(decide([window(0, origin)], known: []) == .navigate(0))
  }

  @Test("matches windows by origin regardless of spelling")
  func originEquality() throws {
    let spelled = try ServerOrigin(serialized: "HTTPS://My-Workspace.cloud.databricks.com:443")
    #expect(decide([window(0, spelled)], known: []) == .navigate(0))
  }
}
