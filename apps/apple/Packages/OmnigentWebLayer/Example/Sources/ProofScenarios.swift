internal import AppKit
internal import Darwin
internal import Foundation
internal import OmnigentWebLayer

/// The proof scenarios.
extension Proofs {

  func boot() async throws {
    let readyBeforeCapture = model.session.isReady
    let shot = try await screenshot("owl-boot-starting")
    Clock.log("captured \(shot.lastPathComponent) with host ready=\(readyBeforeCapture)")
    try await model.session.waitUntilReady()
    guard let info = model.session.hostInfo else { throw ProofFailure("No host info.") }
    Clock.log(
      "host ready: pid \(info.pid), CEF \(info.cefVersion), Chromium \(info.chromiumVersion), protocol \(info.protocolVersion), mode \(info.renderMode.rawValue)"
    )
    Clock.log(
      "timings: spawn \(ms(info.spawnDuration)) ms, hello \(ms(info.helloDuration)) ms, ready \(ms(info.readyDuration)) ms (host-measured init \(info.hostInitMilliseconds) ms)"
    )
  }

  func render() async throws {
    try await load(URL(string: "https://example.com"), title: "Example Domain")
    try await waitUntil("first frame", timeout: 10) { self.webView.statistics.framesPresented > 0 }
    try await settle()
    Clock.log("frames presented so far: \(webView.statistics.framesPresented)")
    try await screenshot("owl-example-com-\(modeName)")
  }

  /// Detects a broken rendering path: the window server's view of the page (screencapture) must
  /// show the color the host rendered (snapshot). A CALayerHost that silently stops working
  /// leaves the view blank and fails this check.
  func pixels() async throws {
    try await load(
      Self.page("<title>OWL pixels</title><body style='background:#d02090'>"),
      title: "OWL pixels")
    try await waitUntil("first frame", timeout: 10) { self.webView.statistics.framesPresented > 0 }
    try await settle(0.5)
    let shot = try await screenshot("owl-pixels-\(modeName)")
    guard let surface, let window,
      let screen = NSBitmapImageRep(data: try Data(contentsOf: shot)),
      let page = NSBitmapImageRep(data: try await webView.snapshotPNG())
    else {
      throw ProofFailure("Could not read the captures.")
    }
    let center = surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
    let scale = Double(screen.pixelsWide) / window.frame.width
    let onScreen = screen.colorAt(
      x: Int(center.x * scale), y: Int((window.frame.height - center.y) * scale))
    let rendered = page.colorAt(x: page.pixelsWide / 2, y: page.pixelsHigh / 2)
    Clock.log(
      "pixels: on screen \(String(describing: onScreen)), host rendered \(String(describing: rendered))"
    )
    guard let onScreen, let rendered,
      abs(onScreen.redComponent - rendered.redComponent) < 0.1,
      abs(onScreen.greenComponent - rendered.greenComponent) < 0.1,
      abs(onScreen.blueComponent - rendered.blueComponent) < 0.1
    else {
      throw ProofFailure("The window does not show what the host rendered.")
    }
  }

  func input() async throws {
    try await load(Self.formPage, title: "OWL form")
    let field = try await center(of: "#name")
    click(at: field)
    try await settle(0.2)
    type("hello owl")
    let button = try await center(of: "#go")
    click(at: button)
    try await settle(0.3)
    let value = try await webView.evaluateJavaScript("document.querySelector('#name').value")
    let clicks = try await webView.evaluateJavaScript("window.clicks")
    Clock.log("input value=\(value) clicks=\(clicks)")
    guard value == .string("hello owl"), clicks == .number(1) else {
      throw ProofFailure("Expected 'hello owl' and 1 click, got \(value) and \(clicks).")
    }
    try await screenshot("owl-input-\(modeName)")
  }

  func select() async throws {
    try await load(Self.selectPage, title: "OWL select")
    let menu = try await center(of: "#fruit")
    click(at: menu)
    try await settle(0.8)
    try await screenshot("owl-select-popup-\(modeName)")
    let snapshot = try await webView.snapshotPNG()
    let snapshotURL = outputDirectory.appending(path: "owl-select-snapshot-\(modeName).png")
    try snapshot.write(to: snapshotURL)
    Clock.log("wrote \(snapshotURL.lastPathComponent) (\(snapshot.count) bytes, popup composited)")
    key(keyCode: 125, characters: "\u{F701}")
    key(keyCode: 125, characters: "\u{F701}")
    key(keyCode: 36, characters: "\r")
    try await settle(0.5)
    let value = try await webView.evaluateJavaScript("document.querySelector('#fruit').value")
    Clock.log("select value after ArrowDown x2 + Enter: \(value)")
    guard value == .string("cherry") else {
      throw ProofFailure("Expected 'cherry', got \(value).")
    }
  }

  func javascript() async throws {
    try await load(Self.formPage, title: "OWL form")
    let sum = try await webView.evaluateJavaScript("1 + 1")
    let object = try await webView.evaluateJavaScript("({a: [1, 'two', null], b: true})")
    let title = try await webView.evaluateJavaScript("document.title")
    Clock.log("js: 1+1=\(sum) object=\(object) title=\(title)")
    guard sum == .number(2), title == .string("OWL form") else {
      throw ProofFailure("Unexpected evaluation results.")
    }
    do {
      _ = try await webView.evaluateJavaScript("throw new Error('boom')")
      throw ProofFailure("A throwing script did not fail.")
    } catch let error as WebLayerError {
      Clock.log("throwing script surfaced: \(error.localizedDescription)")
    }
    let png = try await webView.snapshotPNG()
    let url = outputDirectory.appending(path: "owl-snapshot-\(modeName).png")
    try png.write(to: url)
    guard let image = NSImage(data: png), image.size.width > 100 else {
      throw ProofFailure("Snapshot is not a usable PNG.")
    }
    Clock.log(
      "snapshot \(url.lastPathComponent): \(Int(image.size.width))x\(Int(image.size.height))")
  }

  func unhandledKeys() async throws {
    try await load(Self.formPage, title: "OWL form")
    click(at: try await center(of: "#go"))
    try await settle(0.2)
    let before = model.unhandledProbeCount
    guard let window else { throw ProofFailure("No window.") }
    let event = keyEvent(
      .keyDown, keyCode: 32, characters: "U", unmodified: "u", modifiers: [.command, .shift])
    _ = window.performKeyEquivalent(with: event)
    try await waitUntil("unhandled Cmd+Shift+U reaches the menu", timeout: 3) {
      self.model.unhandledProbeCount > before
    }
    Clock.log("page saw keydown and released it; menu fired")
  }

  func cookies() async throws {
    let server = try ProofServer()
    try await server.start()
    defer { server.stop() }
    let base = "http://127.0.0.1:\(server.port)"
    try await load(URL(string: "\(base)/set?v=default"), title: "set")
    try await load(URL(string: "\(base)/read"), title: "read")
    let defaultCookie = try await resultText(webView)
    let agentA = model.session.makeEphemeralProfile(label: "agent-a")
    let agentB = model.session.makeEphemeralProfile(label: "agent-b")
    defer {
      agentA.close()
      agentB.close()
    }
    let viewA = agentA.makeWebView(initialURL: URL(string: "\(base)/read"))
    try await waitForLoad(viewA, title: "read")
    let agentACookieBefore = try await resultText(viewA)
    viewA.load(try url("\(base)/set?v=agent-a"))
    try await waitForLoad(viewA, title: "set")
    viewA.load(try url("\(base)/read"))
    try await waitForLoad(viewA, title: "read")
    let agentACookieAfter = try await resultText(viewA)
    let viewB = agentB.makeWebView(initialURL: URL(string: "\(base)/read"))
    try await waitForLoad(viewB, title: "read")
    let agentBCookie = try await resultText(viewB)
    webView.reload()
    try await waitForLoad(webView, title: "read")
    let defaultCookieAfter = try await resultText(webView)
    Clock.log("default profile: \(defaultCookie)")
    Clock.log("ephemeral A before set: \(agentACookieBefore); after set: \(agentACookieAfter)")
    Clock.log("ephemeral B: \(agentBCookie)")
    Clock.log("default profile after agents: \(defaultCookieAfter)")
    guard defaultCookie == "cookie: owl=default", agentACookieBefore == "cookie: (none)",
      agentACookieAfter == "cookie: owl=agent-a", agentBCookie == "cookie: (none)",
      defaultCookieAfter == "cookie: owl=default"
    else {
      throw ProofFailure("Cookies leaked between profiles.")
    }
    try await screenshot("owl-cookies-\(modeName)")
  }

  func agentInput() async throws {
    let agent = model.session.makeEphemeralProfile(label: "agent-input")
    defer { agent.close() }
    let view = agent.makeWebView(initialURL: Self.formPage)
    try await waitForLoad(view, title: "OWL form")
    let field = try await center(of: "#name", in: view)
    try view.renderer.agentClick(at: field)
    try view.renderer.agentType("agent typed")
    try view.renderer.agentPress(.enter)
    try view.renderer.agentClick(at: try await center(of: "#go", in: view))
    try await settle(0.4)
    let value = try await view.evaluateJavaScript("document.querySelector('#name').value")
    let clicks = try await view.evaluateJavaScript("window.clicks")
    let submitted = try await view.evaluateJavaScript("window.submitted")
    Clock.log("agent view (not on screen): value=\(value) clicks=\(clicks) enter=\(submitted)")
    guard value == .string("agent typed"), clicks == .number(1), submitted == .number(1) else {
      throw ProofFailure("Agent input did not reach the page.")
    }
    view.setVisible(false)
    let hidden = try await view.snapshotPNG()
    let image = NSImage(data: hidden)
    Clock.log("hidden agent view snapshot: \(hidden.count) bytes, \(image?.size ?? .zero)")
    guard image != nil else { throw ProofFailure("A hidden view could not be captured.") }
    try hidden.write(to: outputDirectory.appending(path: "owl-agent-hidden-snapshot.png"))
  }

  func crashRecovery() async throws {
    try await load(URL(string: "https://example.com"), title: "Example Domain")
    try await waitForPage()
    guard let pid = model.session.hostInfo?.pid else { throw ProofFailure("Host not ready.") }
    let title = webView.title
    let killed = ContinuousClock.now
    guard kill(pid, SIGKILL) == 0 else { throw ProofFailure("kill failed: errno \(errno)") }
    try await waitUntil("view reports the host exit", timeout: 5) {
      if case .unavailable = self.webView.status { return true }
      return false
    }
    Clock.log(
      "host \(pid) killed; app alive; detected in \(ms(ContinuousClock.now - killed)) ms; session \(model.session.state)"
    )
    try await settle(0.5)
    try await screenshot("owl-host-killed-\(modeName)")
    let reload = ContinuousClock.now
    webView.reload()
    try await waitUntil("host restarts and the page reloads", timeout: 30) {
      self.webView.status == .live && !self.webView.isLoading && self.webView.title == title
    }
    let newPID = model.session.hostInfo?.pid ?? 0
    Clock.log(
      "reload restarted host \(newPID) and reloaded in \(ms(ContinuousClock.now - reload)) ms")
    guard newPID != pid else { throw ProofFailure("The host pid did not change.") }
    try await settle()
    try await screenshot("owl-host-restarted-\(modeName)")
  }

  func hangRecovery() async throws {
    try await waitForPage()
    guard let pid = model.session.hostInfo?.pid else { throw ProofFailure("Host not ready.") }
    let stopped = ContinuousClock.now
    guard kill(pid, SIGSTOP) == 0 else { throw ProofFailure("kill failed: errno \(errno)") }
    try await waitUntil("watchdog declares the host hung", timeout: 20) {
      if case .unavailable(.hostUnresponsive) = self.webView.status { return true }
      return false
    }
    Clock.log(
      "SIGSTOPped host \(pid) detected as hung after \(ms(ContinuousClock.now - stopped)) ms")
    webView.reload()
    try await waitUntil("host restarts after a hang", timeout: 30) {
      self.webView.status == .live && !self.webView.isLoading
    }
    Clock.log("recovered with host \(model.session.hostInfo?.pid ?? 0)")
  }

  /// Measures frame delivery for the current render mode, idle and with the client's main thread
  /// blocked 40 ms of every 50 ms.
  func renderingSpike() async throws {
    try await load(Self.animationPage, title: "OWL animation")
    try await settle(1)
    for phase in ["idle", "jank"] {
      let framesBefore = webView.statistics.framesPresented
      let rafBefore = try await number("window.rafFrames")
      let started = ContinuousClock.now
      let clientCPUBefore = cpuSeconds(getpid())
      let hostPID = model.session.hostInfo?.pid ?? 0
      let hostCPUBefore = cpuSeconds(hostPID)
      while ContinuousClock.now - started < .seconds(3) {
        if phase == "jank" { usleep(40_000) }
        try await Task.sleep(for: .milliseconds(10))
      }
      let seconds =
        Double((ContinuousClock.now - started).components.seconds)
        + Double((ContinuousClock.now - started).components.attoseconds) / 1e18
      let rafAfter = try await number("window.rafFrames")
      let stats = webView.statistics
      let delivered = stats.framesPresented - framesBefore
      let recent = Array(stats.latencyMicroseconds.suffix(max(1, delivered)))
      let copies = Array(stats.copyMicroseconds.suffix(max(1, delivered)))
      Clock.log(
        "spike \(modeName) \(phase): page rAF \(Int((rafAfter - rafBefore) / seconds)) fps, delivered \(Int(Double(delivered) / seconds)) fps, paint->present p50 \(percentile(recent, 0.5)) us p95 \(percentile(recent, 0.95)) us, copy p50 \(percentile(copies, 0.5)) us, dropped total \(stats.framesDropped), CPU client \(cpuPercent(clientCPUBefore, cpuSeconds(getpid()), seconds))% host \(cpuPercent(hostCPUBefore, cpuSeconds(hostPID), seconds))%"
      )
    }
    try await screenshot("owl-spike-\(modeName)")
  }
}
