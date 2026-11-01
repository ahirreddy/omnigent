internal import AppKit
internal import Darwin
internal import Foundation
internal import OmnigentWebLayer

/// Waiting, input synthesis, capture and measurement for the proofs.
extension Proofs {

  /// The mode in effect, or the requested one while the host is down.
  var modeName: String {
    (model.session.hostInfo?.renderMode ?? model.options.renderMode).rawValue
  }

  var window: NSWindow? {
    NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
  }

  var surface: NSView? {
    guard let root = window?.contentView else { return nil }
    return Self.find(WebLayerView.self, in: root)?.subviews.first
  }

  static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    for subview in view.subviews {
      if let match = find(type, in: subview) { return match }
    }
    return nil
  }

  func ms(_ duration: Duration) -> Int {
    Int(
      duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
  }

  func url(_ string: String) throws -> URL {
    guard let url = URL(string: string) else { throw ProofFailure("Bad URL \(string)") }
    return url
  }

  func waitUntil(
    _ what: String, timeout: Double, _ condition: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
    while !condition() {
      if ContinuousClock.now > deadline { throw ProofFailure("Timed out: \(what)") }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func settle(_ seconds: Double = 0.6) async throws {
    try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
  }

  func waitForPage() async throws {
    try await model.session.waitUntilReady()
    defer {
      Clock.log(
        "page state: status \(webView.status) loading \(webView.isLoading) title '\(webView.title)' frames \(webView.statistics.framesPresented) error \(String(describing: webView.lastError))"
      )
    }
    try await waitUntil("first page", timeout: 30) {
      self.webView.status == .live && !self.webView.isLoading && !self.webView.title.isEmpty
        && self.webView.statistics.framesPresented > 0
    }
  }

  func load(_ url: URL?, title: String) async throws {
    guard let url else { throw ProofFailure("Bad URL") }
    try await model.session.waitUntilReady()
    try await waitUntil("view live", timeout: 30) { self.webView.status == .live }
    webView.load(url)
    try await waitForLoad(webView, title: title)
  }

  func waitForLoad(_ view: WebView, title: String) async throws {
    try await Task.sleep(for: .milliseconds(100))
    try await waitUntil("load '\(title)'", timeout: 30) {
      if let error = view.lastError, !error.isCancellation { return true }
      return view.status == .live && !view.isLoading && view.title == title
    }
    if let error = view.lastError, !error.isCancellation { throw error }
  }

  func resultText(_ view: WebView) async throws -> String {
    let value = try await view.evaluateJavaScript("document.querySelector('#result').textContent")
    return value.stringValue ?? "\(value)"
  }

  func number(_ script: String) async throws -> Double {
    guard case .number(let value) = try await webView.evaluateJavaScript(script) else {
      throw ProofFailure("\(script) is not a number")
    }
    return value
  }

  func center(of selector: String, in view: WebView? = nil) async throws -> CGPoint {
    let script =
      "(() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()"
    guard case .array(let values) = try await (view ?? webView).evaluateJavaScript(script),
      values.count == 2, case .number(let pointX) = values[0], case .number(let pointY) = values[1]
    else {
      throw ProofFailure("Cannot locate \(selector)")
    }
    return CGPoint(x: pointX, y: pointY)
  }

  func click(at viewPoint: CGPoint) {
    guard let surface, let window else { return }
    let location = surface.convert(viewPoint, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      if let event = NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
      {
        window.sendEvent(event)
      }
    }
  }

  func type(_ text: String) {
    for character in text {
      let string = String(character)
      key(keyCode: Self.keyCodes[character] ?? 0, characters: string)
    }
  }

  func key(keyCode: UInt16, characters: String) {
    guard let window else { return }
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      window.sendEvent(
        keyEvent(type, keyCode: keyCode, characters: characters, unmodified: characters))
    }
  }

  func keyEvent(
    _ type: NSEvent.EventType, keyCode: UInt16, characters: String, unmodified: String,
    modifiers: NSEvent.ModifierFlags = []
  ) -> NSEvent {
    guard
      let event = NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
        context: nil, characters: characters, charactersIgnoringModifiers: unmodified,
        isARepeat: false, keyCode: keyCode)
    else {
      fatalError("NSEvent.keyEvent returned nil for key code \(keyCode)")
    }
    return event
  }

  @discardableResult
  func screenshot(_ name: String) async throws -> URL {
    guard let window else { throw ProofFailure("No window to capture.") }
    let url = outputDirectory.appending(path: "\(name).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
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

  func cpuSeconds(_ pid: pid_t) -> Double {
    var info = rusage_info_current()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      unsafe pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        unsafe proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
      }
    }
    guard result == 0 else { return 0 }
    var timebase = mach_timebase_info_data_t()
    guard unsafe mach_timebase_info(&timebase) == KERN_SUCCESS else { return 0 }
    let ticks = Double(info.ri_user_time + info.ri_system_time)
    return ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
  }

  func cpuPercent(_ before: Double, _ after: Double, _ seconds: Double) -> Int {
    Int(((after - before) / seconds * 100).rounded())
  }

  func percentile(_ values: [Double], _ fraction: Double) -> Int {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return Int(sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))])
  }

  static let keyCodes: [Character: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
    "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49,
  ]
}
