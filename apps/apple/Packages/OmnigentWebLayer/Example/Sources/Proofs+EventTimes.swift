internal import AppKit
internal import Foundation
internal import OmnigentWebLayer

/// Input reaches the page stamped with the time it happened. See DESIGN.md, "Input".
extension Proofs {
  static let eventTimePages: [String: String] = [
    "event-times": """
    <!doctype html><title>OWL event times</title>\(pageStyle)<h2>Event times</h2>
    <button id=tap>Tap</button> <input id=field placeholder="type here">
    <p><a id=route href="/page/event-times/next">Change the route</a></p>
    <div id=view>First view</div><p id=result>none</p>
    <script>
    // Per event name: the time the event says it happened, and the time its handler ran.
    window.seen = {};
    const see = (name) => (e) => { window.seen[name] = [e.timeStamp, performance.now()]; };
    document.querySelector('#tap').addEventListener('click', see('click'));
    document.querySelector('#field').addEventListener('keydown', see('key'));
    document.querySelector('#route').addEventListener('click', (e) => {
      e.preventDefault();
      history.pushState({}, '', '/page/event-times/next');
      document.querySelector('#view').innerHTML = '<h1>Second view</h1><p>'
        + 'The second view replaces the first. '.repeat(60) + '</p>';
      document.querySelector('#result').textContent = 'routed';
    });
    </script>
    """
  ]

  /// Milliseconds an injected event may be old by the time its handler runs.
  private static let recentAge = -5.0...2000.0

  func eventTimes() async throws {
    try await load(try await pageURL("event-times"), title: "OWL event times")
    // Longer than `recentAge`, so an event stamped with no time or the page's own start fails.
    try await settle(4)
    let tap = try await center(of: "#tap")
    let field = try await center(of: "#field")

    click(at: tap, happened: ProcessInfo.processInfo.systemUptime - 0.5)
    let heldClick = try await eventAge("click")
    click(at: field)
    key(keyCode: 0, characters: "a")
    let userKey = try await eventAge("key")
    Clock.log(
      "user input: a click sent 500 ms late is \(heldClick.rounded()) ms old, a key \(userKey.rounded())"
    )
    guard heldClick >= 400, Self.recentAge.contains(heldClick) else {
      throw ProofFailure("The click's own time did not reach the page: \(heldClick) ms old.")
    }
    guard Self.recentAge.contains(userKey) else {
      throw ProofFailure("A user key was \(userKey) ms old.")
    }

    try webView.renderer.agentClick(at: tap)
    let agentClick = try await eventAge("click")
    try webView.renderer.agentClick(at: field)
    try webView.renderer.agentPress(.character("b"))
    let agentKey = try await eventAge("key")
    Clock.log(
      "agent input: click \(agentClick.rounded()) ms old, key \(agentKey.rounded()) ms old")
    guard Self.recentAge.contains(agentClick), Self.recentAge.contains(agentKey) else {
      throw ProofFailure("Agent input was \(agentClick) and \(agentKey) ms old.")
    }
    try await routeChange()
  }

  /// A click that changes the route without a reload. Chromium measures such a soft navigation
  /// from the click's time and ends the renderer when that is older than the document.
  private func routeChange() async throws {
    click(at: try await center(of: "#route"))
    try await waitUntil("the route changes", timeout: 5) {
      self.webView.url?.path.hasSuffix("/next") == true
    }
    // The soft navigation is reported after the new view paints.
    try await settle(2)
    if case .rendererTerminated(let detail) = webView.lastError {
      throw ProofFailure("The renderer ended on the route change: \(detail)")
    }
    let result = try await resultText(webView)
    Clock.log("route changed to \(webView.url?.path ?? "-") without a reload; page says \(result)")
    guard result == "routed" else { throw ProofFailure("The page did not route: \(result)") }
  }

  /// Waits for the page to see an event of `name`; returns how many milliseconds before its
  /// handler ran the event says it happened.
  private func eventAge(_ name: String) async throws -> Double {
    let script =
      "(() => { const seen = window.seen['\(name)']; delete window.seen['\(name)']; return seen ?? null; })()"
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if case .array(let values) = try await webView.evaluateJavaScript(script), values.count == 2,
        case .number(let happened) = values[0], case .number(let handled) = values[1]
      {
        // Chromium reports an event stamped before its document, or not at all, as time 0.
        guard happened > 0 else { throw ProofFailure("The \(name) event carries no time.") }
        return handled - happened
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw ProofFailure("The page saw no \(name) event.")
  }
}
