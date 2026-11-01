internal import AppKit
internal import Foundation
internal import OmnigentBrowser
internal import OmnigentWebLayer

/// Chromium-only proofs: on WebKit the context menu, IME, drag and drop and color picker are
/// WKWebView's own native implementations.
extension Proofs {
  private func webLayerView(_ tab: any BrowserTab) throws -> WebLayerView {
    guard let view = tab.platformView as? WebLayerView else {
      throw ProofFailure("The Chromium tab is not a WebLayerView.")
    }
    return view
  }

  func contextMenu() async throws {
    if skipOnWebKit("WKWebView shows its own native context menu") { return }
    let (harness, tab) = try await harness(try await pageURL("menu"), title: "OWL menu")
    defer { harness.close() }
    let probe = MenuProbe()
    let observer = NotificationCenter.default.addObserver(
      forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
    ) { note in
      // AppKit posts menu tracking on the main thread and this observer runs on `.main`, so the
      // menu never leaves the main actor; the closure type is merely @Sendable.
      nonisolated(unsafe) let menu = note.object as? NSMenu
      MainActor.assumeIsolated { unsafe probe.opened(menu, proofs: self, window: harness.window) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    NSPasteboard.general.clearContents()
    try await userClick(tab, "#link", in: harness.window, right: true)
    try await waitUntil("Copy Link puts the link on the pasteboard", timeout: 10) {
      NSPasteboard.general.string(forType: .string) == "https://example.com/owl2-menu-link"
    }
    Clock.log("link menu items: \(probe.titles)")
    probe.pick = "Copy"
    try await eval(
      tab,
      "getSelection().selectAllChildren(document.querySelector('#text')); 'selected'")
    NSPasteboard.general.clearContents()
    try await userClick(tab, "#text", in: harness.window, right: true)
    try await waitUntil("the host's Copy command copies the selection", timeout: 10) {
      NSPasteboard.general.string(forType: .string)?.contains("Selectable proof text") == true
    }
    Clock.log("text menu items: \(probe.titles); host command Copy ran")
  }

  /// Captures an open context menu, then picks `pick` from it.
  final class MenuProbe {
    var titles: [String] = []
    var pick = "Copy Link"

    /// The menu runs a modal tracking loop, so this uses a timer in the common modes (which the
    /// tracking loop services) and captures synchronously.
    func opened(_ menu: NSMenu?, proofs: Proofs, window: NSWindow) {
      guard let menu else { return }
      titles = menu.items.map(\.title)
      let pick = pick
      let path = proofs.outputDirectory
        .appending(
          path:
            "owl2-context-menu-\(pick == "Copy Link" ? "link" : "text")-\(proofs.engineSuffix).png")
      // The timer fires on the main run loop, so the menu and window stay on the main actor.
      nonisolated(unsafe) let tracked = menu
      let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
        MainActor.assumeIsolated {
          unsafe Self.finish(tracked, pick: pick, window: window, path: path)
        }
      }
      RunLoop.main.add(timer, forMode: .common)
    }

    private static func finish(_ menu: NSMenu, pick: String, window: NSWindow, path: URL) {
      capture(window.frame, to: path)
      if let index = menu.items.firstIndex(where: { $0.title == pick }) {
        menu.performActionForItem(at: index)
      } else {
        Clock.log("FAIL the context menu has no \(pick) item: \(menu.items.map(\.title))")
      }
      menu.cancelTracking()
    }

    private static func capture(_ frame: NSRect, to url: URL) {
      let top = NSScreen.screens.first?.frame.maxY ?? frame.maxY
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = [
        "-x",
        "-R\(Int(frame.minX)),\(Int(top - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))",
        url.path,
      ]
      do {
        try process.run()
        process.waitUntilExit()
        Clock.log("screenshot \(url.path) (status \(process.terminationStatus))")
      } catch {
        Clock.log("FAIL context menu capture: \(error)")
      }
    }
  }

  func ime() async throws {
    if skipOnWebKit("WKWebView implements NSTextInputClient itself") { return }
    let (harness, tab) = try await harness(try await pageURL("ime"), title: "OWL IME")
    defer { harness.close() }
    try await userClick(tab, "#field", in: harness.window)
    try await settle(0.3)
    guard let client = try webLayerView(tab).subviews.first as? (any NSTextInputClient & NSView)
    else {
      throw ProofFailure("The page surface is not an NSTextInputClient.")
    }
    harness.window.makeFirstResponder(client)
    let none = NSRange(location: NSNotFound, length: 0)
    // What an input method does while the user composes 日本語.
    for marked in ["に", "にほ", "日本"] {
      client.setMarkedText(
        marked, selectedRange: NSRange(location: marked.utf16.count, length: 0),
        replacementRange: none)
      try await settle(0.15)
    }
    try await shoot(harness.window, "ime-composing")
    Clock.log("marked text: \(client.hasMarkedText()), range \(client.markedRange())")
    client.insertText("日本語", replacementRange: none)
    let value = try await eval(tab, "document.querySelector('#field').value")
    let events = try await text(tab)
    Clock.log("IME value=\(value) events: \(events)")
    guard value == .string("日本語"), events.contains("compositionstart"),
      events.contains("compositionend:日本語")
    else {
      throw ProofFailure("The composition did not commit as 日本語.")
    }
    try await shoot(harness.window, "ime-committed")
  }

  func dragAndDrop() async throws {
    if skipOnWebKit("WKWebView handles drag and drop natively") { return }
    let (harness, tab) = try await harness(try await pageURL("drag"), title: "OWL drag")
    defer { harness.close() }
    let webView = try webLayerView(tab).webView
    let file = FileManager.default.temporaryDirectory.appending(path: "owl2-drop.txt")
    try Data("dropped file".utf8).write(to: file)
    let target = try await center(tab, "#drop")
    let renderer = webView.renderer
    renderer.dragEntered(
      WebDragData(text: "dropped text", paths: [file.path]), at: target, operations: [.copy])
    renderer.dragUpdated(at: target, operations: [.copy])
    try await settle(0.2)
    renderer.performDrop(at: target)
    let result = try await waitText(tab, { $0.hasPrefix("text=") }, "drop")
    Clock.log("drop into the page: \(result); page accepted \(webView.dragOperation)")
    guard result == "text=dropped text files=owl2-drop.txt" else {
      throw ProofFailure("The page did not receive the dropped text and file.")
    }
    try await shoot(harness.window, "drag-dropped")
    var started: WebDragData?
    webView.onEvent = { event in
      if case .dragStarted(let data) = event { started = data }
    }
    try await dragOut(tab, from: "#source", in: harness.window)
    let data = try await waitFor("the page starts a native drag", timeout: 5) { started }
    Clock.log("drag out of the page started a native drag with text '\(data.text ?? "")'")
    guard data.text == "drag me out" else { throw ProofFailure("Wrong drag data: \(data)") }
  }

  private func dragOut(_ tab: any BrowserTab, from selector: String, in window: NSWindow)
    async throws
  {
    let start = try await center(tab, selector)
    let view = tab.platformView
    for (index, type) in [
      NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseDragged,
    ].enumerated() {
      let point = CGPoint(x: start.x + Double(index) * 12, y: start.y + Double(index) * 6)
      let location = view.convert(NSPoint(x: point.x, y: view.bounds.height - point.y), to: nil)
      guard
        let event = NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
      else {
        throw ProofFailure("Cannot synthesize \(type)")
      }
      window.sendEvent(event)
      try await settle(0.08)
    }
  }

  func color() async throws {
    if skipOnWebKit("WKWebView opens NSColorPanel itself") { return }
    let (harness, tab) = try await harness(try await pageURL("color"), title: "OWL color")
    defer { harness.close() }
    try await userClick(tab, "#color", in: harness.window)
    guard
      case .color(let prompt) = try await waitFor("color prompt", { pendingPrompt(tab, "color") })
    else {
      throw ProofFailure("No color prompt.")
    }
    try await waitUntil("the client's color panel opens", timeout: 5) {
      NSColorPanel.shared.isVisible
    }
    Clock.log("color prompt with \(prompt.initialColor); the host did not open its own panel")
    try await settle(0.5)
    try await shoot(NSColorPanel.shared, "color-panel")
    try await shoot(harness.window, "color-page")
    prompt.choose("#00ff00")
    NSColorPanel.shared.close()
    let result = try await waitText(tab, { $0.hasPrefix("changed:") }, "color change")
    Clock.log("page saw \(result)")
    guard result == "changed:#00ff00" else { throw ProofFailure("Wrong color: \(result)") }
  }
}
