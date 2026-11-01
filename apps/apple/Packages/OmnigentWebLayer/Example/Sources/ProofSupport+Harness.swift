internal import AppKit
internal import Foundation
internal import OmnigentBrowser
internal import OmnigentWebLayer

/// Helpers for proofs that drive the shared browser UI.
extension Proofs {
  /// "chromium-remoteLayer", "chromium-ioSurface" or "webkit", for screenshot names.
  var engineSuffix: String { engine == .system ? "webkit" : "chromium-\(modeName)" }

  func proofServer() async throws -> ProofServer {
    if let server { return server }
    let started = try ProofServer(pages: Self.servedPages)
    try await started.start()
    server = started
    return started
  }

  func pageURL(_ name: String) async throws -> URL {
    try url("\(try await proofServer().base)/page/\(name)")
  }

  /// Opens the shared UI for the proof engine at `url` and waits for `title`.
  func harness(
    _ url: URL?, title: String?,
    profile: BrowserProfile = .ephemeral("owl2-proof-\(UUID().uuidString)")
  ) async throws -> (BrowserHarness, any BrowserTab) {
    if engine == .chromium { try await model.session.waitUntilReady() }
    let harness = try BrowserHarness(kind: engine, provider: provider, profile: profile, url: url)
    let tab = try harness.requireTab()
    if let title { try await waitForTab(tab, title: title) }
    return (harness, tab)
  }

  func waitForTab(_ tab: any BrowserTab, title: String, timeout: Double = 30) async throws {
    try await Task.sleep(for: .milliseconds(150))
    try await waitUntil("tab loads '\(title)'", timeout: timeout) {
      if let error = tab.state.lastError, !error.isCancellation { return true }
      return !tab.state.isLoading && tab.state.title == title
    }
    if let error = tab.state.lastError, !error.isCancellation { throw error }
  }

  func waitFor<T>(_ what: String, timeout: Double = 10, _ value: () -> T?) async throws -> T {
    var found: T?
    try await waitUntil(what, timeout: timeout) {
      found = value()
      return found != nil
    }
    guard let found else { throw ProofFailure("Timed out: \(what)") }
    return found
  }

  @discardableResult
  func eval(_ tab: any BrowserTab, _ script: String) async throws -> BrowserScriptValue {
    try await tab.evaluateJavaScript(script)
  }

  func text(_ tab: any BrowserTab, _ selector: String = "#result") async throws -> String {
    let value = try await eval(tab, "document.querySelector('\(selector)').textContent")
    return value.stringValue ?? "\(value)"
  }

  func waitText(_ tab: any BrowserTab, _ predicate: @escaping (String) -> Bool, _ what: String)
    async throws -> String
  {
    let deadline = ContinuousClock.now + .seconds(15)
    var last = ""
    while ContinuousClock.now < deadline {
      last = try await text(tab)
      if predicate(last) { return last }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ProofFailure("Timed out waiting for \(what); #result is '\(last)'")
  }

  func center(_ tab: any BrowserTab, _ selector: String) async throws -> CGPoint {
    let script =
      "(() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()"
    guard case .array(let values) = try await eval(tab, script), values.count == 2,
      case .number(let pointX) = values[0], case .number(let pointY) = values[1]
    else {
      throw ProofFailure("Cannot locate \(selector)")
    }
    return CGPoint(x: pointX, y: pointY)
  }

  /// A user click through the window, as AppKit would deliver it.
  func userClick(
    _ tab: any BrowserTab, _ selector: String, in window: NSWindow, right: Bool = false
  ) async throws {
    if engine == .system, !right {
      // WKWebView does not take synthesized NSEvents from another source than the window
      // server; its script evaluation runs with a user gesture, which is what the page checks.
      try await eval(tab, "document.querySelector('\(selector)').click(); true")
      return
    }
    let point = try await center(tab, selector)
    let view = tab.platformView
    let local = view.isFlipped ? point : NSPoint(x: point.x, y: view.bounds.height - point.y)
    let location = view.convert(local, to: nil)
    let types: [NSEvent.EventType] =
      right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
    for type in types {
      guard
        let event = NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: type == types[0] ? 1 : 0)
      else {
        throw ProofFailure("Cannot synthesize \(type)")
      }
      // Through NSApp, so `NSApp.currentEvent` is the click, as WebKit expects.
      NSApp.sendEvent(event)
    }
  }

  /// Captures one window as `owl2-<name>-<engine>.png`.
  @discardableResult
  func shoot(_ window: NSWindow, _ name: String) async throws -> URL {
    try await capture(name, ["-l\(window.windowNumber)"])
  }

  /// Captures the screen area of `window` (menus in front of it included), never more.
  @discardableResult
  func shootArea(_ window: NSWindow, _ name: String) async throws -> URL {
    let frame = window.frame
    let screenTop = NSScreen.screens.first?.frame.maxY ?? frame.maxY
    let rect =
      "\(Int(frame.minX)),\(Int(screenTop - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
    return try await capture(name, ["-R\(rect)"])
  }

  private func capture(_ name: String, _ arguments: [String]) async throws -> URL {
    let url = outputDirectory.appending(path: "owl2-\(name)-\(engineSuffix).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o"] + arguments + [url.path]
    try process.run()
    while process.isRunning {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard process.terminationStatus == 0 else {
      throw ProofFailure("screencapture failed with status \(process.terminationStatus)")
    }
    Clock.log("screenshot \(url.path)")
    return url
  }

  /// The pending prompt of a kind, as the presenter received it.
  func pendingPrompt(_ tab: any BrowserTab, _ kind: String) -> BrowserPrompt? {
    tab.state.pendingPrompts.first { $0.kindName == kind }
  }

  func skipOnWebKit(_ reason: String) -> Bool {
    guard engine == .system else { return false }
    Clock.log("SKIP on WebKit: \(reason)")
    return true
  }
}
