internal import AppKit
internal import Foundation
internal import OmnigentWebLayer

/// Tabs switched away from and back to, as the app's tab strip does: one web view in the window
/// at a time, the others taken out of it. There are more hidden pages than Chromium keeps frames
/// for, so it evicts the oldest; each page animates, and every show must be followed by frames.
extension Proofs {
  static let tabSwitchPages: [String: String] = [
    "tab-switch": """
    <!doctype html><title>OWL tab switch</title>\(pageStyle)<h2>Tab</h2>
    <style>@keyframes spin { to { transform: rotate(360deg) } }
    #spinner { width: 120px; height: 120px; background: linear-gradient(45deg, #36f, #f63);
      animation: spin 1.5s linear infinite; margin: 24px }</style>
    <div id=spinner></div><p id=count>0</p>
    <script>
    window.tab = { frames: 0, ticks: 0, freezes: 0 };
    document.addEventListener('freeze', () => window.tab.freezes++);
    setInterval(() => window.tab.ticks++, 100);
    (function tick() {
      window.tab.frames++;
      document.querySelector('#count').textContent = window.tab.frames;
      requestAnimationFrame(tick);
    })();
    </script>
    """
  ]

  /// One page of the tab-switch proof and the view that shows it.
  private struct SwitchTab {
    let view: WebView
    let layer: WebLayerView
  }

  /// Sixteen pages in one window, each shown in turn as the strip does after all of them but one
  /// were hidden for a minute and a half, twice over, while four more pages animate in no window.
  /// A page that answers at once yet has no frame 40 s after it is shown fails the proof, as does
  /// a host that stops; a page that is only late, or too busy to answer, is logged.
  func tabSwitch() async throws {
    try await model.session.waitUntilReady()
    let window = NSWindow(
      contentRect: NSRect(x: 80, y: 80, width: 1100, height: 760),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    guard let container = window.contentView else { throw ProofFailure("No content view.") }
    let tabs = try await openSwitchTabs(16, in: container)
    defer { for tab in tabs { tab.view.close() } }
    let animation = try await pageURL("soak-animation")
    let crowd = (0..<4).map { _ in model.profile.makeWebView(initialURL: animation) }
    defer { for view in crowd { view.close() } }
    for view in crowd { view.rendersOffscreen = true }
    var current: SwitchTab?
    var frozen: [String] = []
    for pass in 0..<2 {
      try await settle(90)
      for turn in 0..<tabs.count {
        let index = (turn * 7 + 3) % tabs.count
        current?.layer.removeFromSuperview()
        current = tabs[index]
        if let failure = try await show(tabs[index], in: window, label: "pass \(pass) tab \(index)")
        {
          frozen.append(failure)
        }
        try await settle(1)
      }
    }
    if tabs.contains(where: { $0.view.status != .live }) {
      throw ProofFailure("The host stopped during the proof.")
    }
    Clock.log("tab-switch: \(2 * tabs.count) shows over \(tabs.count) tabs, \(frozen.count) froze")
    if !frozen.isEmpty {
      throw ProofFailure(
        "\(frozen.count) shows froze: \(frozen.joined(separator: " | "))")
    }
  }

  /// Loads `count` pages, each shown until it draws and then taken out of the window, every other
  /// one from another site so that two renderers share them.
  private func openSwitchTabs(_ count: Int, in container: NSView) async throws -> [SwitchTab] {
    let base = try await pageURL("tab-switch")
    var tabs: [SwitchTab] = []
    for index in 0..<count {
      var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
      parts?.host = index.isMultiple(of: 2) ? "localhost" : "127.0.0.1"
      parts?.query = "tab=\(index)"
      let view = model.profile.makeWebView(initialURL: parts?.url)
      let layer = WebLayerView(webView: view)
      layer.autoresizingMask = [.width, .height]
      layer.frame = container.bounds
      container.addSubview(layer)
      tabs.append(SwitchTab(view: view, layer: layer))
      try await waitForLoad(view, title: "OWL tab switch")
      try await waitUntil("tab \(index) draws", timeout: 10) {
        view.statistics.framesPresented > 5
      }
      layer.removeFromSuperview()
    }
    return tabs
  }

  /// Puts `tab` in the window with the keyboard, as selecting a tab does, and waits for frames.
  /// Returns a description of the freeze when none came within 40 s.
  private func show(_ tab: SwitchTab, in window: NSWindow, label: String) async throws
    -> String?
  {
    guard let container = window.contentView else { throw ProofFailure("No content view.") }
    let frames = tab.view.statistics.framesPresented
    tab.layer.frame = container.bounds
    container.addSubview(tab.layer)
    window.makeFirstResponder(tab.layer.keyboardView)
    let shown = ContinuousClock.now
    if try await framesArrive(tab.view, after: frames, within: 10) {
      let wait = ms(ContinuousClock.now - shown)
      if wait > 1000 { Clock.log("tab-switch \(label): first frame \(wait) ms after show") }
      return nil
    }
    let asked = ContinuousClock.now
    let state = await pageState(tab.view)
    let answer = ms(ContinuousClock.now - asked)
    Clock.log(
      "tab-switch \(label): no frame 10 s after show, page answered in \(answer) ms: \(state)")
    if try await framesArrive(tab.view, after: frames, within: 30) {
      Clock.log("tab-switch \(label): first frame \(ms(ContinuousClock.now - shown)) ms after show")
      return nil
    }
    guard answer < 2000, !state.hasPrefix("unreadable") else {
      Clock.log("tab-switch \(label): no frame 40 s after show; the page did not answer at once")
      return nil
    }
    let failure = "\(label) view \(tab.view.id): no frame 40 s after show, page \(state)"
    Clock.log("tab-switch FROZEN \(failure)")
    return failure
  }

  /// Whether the view presents frames within `seconds`.
  private func framesArrive(_ view: WebView, after frames: Int, within seconds: Double)
    async throws -> Bool
  {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
      if view.statistics.framesPresented > frames + 2 { return true }
      try await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  /// What the page says about itself: whether it thinks it is visible, and whether its
  /// animation frames and timers run.
  private func pageState(_ view: WebView) async -> String {
    let script = "JSON.stringify(Object.assign({visibility: document.visibilityState}, window.tab))"
    do {
      return "\(try await view.evaluateJavaScript(script))"
    } catch {
      return "unreadable (\(error))"
    }
  }
}
