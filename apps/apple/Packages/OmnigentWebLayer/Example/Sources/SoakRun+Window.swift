internal import AppKit
internal import Foundation
internal import OmnigentWebLayer

/// The soak's stretches without input: the window is covered, minimized, hidden with its app,
/// loses its web view, flickers between shown and hidden, changes size, or its page goes back
/// and forward in history.
extension SoakRun {
  /// Covers the window with another window of this app, as a window in front of it would.
  func cover(_ seconds: Double) async throws {
    let cover = NSWindow(
      contentRect: window.frame.insetBy(dx: -8, dy: -8), styleMask: .borderless,
      backing: .buffered, defer: false)
    cover.isReleasedWhenClosed = false
    cover.isOpaque = true
    cover.backgroundColor = .darkGray
    cover.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
    cover.orderFrontRegardless()
    try await away(seconds, until: { !self.window.occlusionState.contains(.visible) })
    cover.orderOut(nil)
    try await back()
  }

  func minimize(_ seconds: Double) async throws {
    window.miniaturize(nil)
    try await away(seconds, until: { !self.window.occlusionState.contains(.visible) })
    window.deminiaturize(nil)
    try await back()
  }

  func hide(_ seconds: Double) async throws {
    NSApp.hide(nil)
    try await away(seconds, until: { !self.window.occlusionState.contains(.visible) })
    NSApp.unhide(nil)
    NSApp.activate()
    try await back()
  }

  /// Takes the web view out of its window and puts it back, as switching tabs does.
  func detach(_ seconds: Double) async throws {
    guard let content = window.contentView,
      let layerView = Proofs.find(WebLayerView.self, in: content),
      // AppKit keeps a view's superview alive while the view is in it.
      let parent = unsafe layerView.superview
    else { throw ProofFailure("The window has no web view to detach.") }
    layerView.removeFromSuperview()
    try await away(seconds, until: { unsafe layerView.superview == nil })
    parent.addSubview(layerView)
    try await shown()
  }

  func away(_ seconds: Double, until gone: () -> Bool) async throws {
    monitor.expectFrames(every: nil)
    let frames = monitor.frames
    try await proofs.waitUntil("the page is off screen", timeout: 5, gone)
    try await proofs.settle(seconds)
    Clock.log("soak away: \(monitor.frames - frames) frame(s) arrived while off screen")
  }

  func back() async throws {
    try await proofs.waitUntil("the window is on screen again", timeout: 10) {
      self.window.occlusionState.contains(.visible)
    }
    window.makeKeyAndOrderFront(nil)
    try await shown()
  }

  func shown() async throws {
    let frames = monitor.frames
    try await monitor.noteShown(every: page.frameInterval)
    try await proofs.settle(1)
    Clock.log("soak back: \(monitor.frames - frames) frame(s) in the first second on screen")
  }

  /// Hides and shows the page in quick succession, as switching tabs or Spaces back and forth
  /// does, and leaves it shown.
  func flap(_ seconds: Double) async throws {
    monitor.expectFrames(every: nil)
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    let pauses = [0, 4, 16, 60, 250, 9, 120, 1, 33]
    var turn = 0
    while ContinuousClock.now < deadline {
      proofs.webView.setVisible(false)
      try await Task.sleep(for: .milliseconds(pauses[turn % pauses.count]))
      proofs.webView.setVisible(true)
      try await Task.sleep(for: .milliseconds(pauses[(turn * 5 + 3) % pauses.count]))
      turn += 1
    }
    Clock.log("soak flap: hidden and shown \(turn) times")
    try await shown()
  }

  /// Goes back to the page before, stays a while, and comes forward again.
  func history(_ seconds: Double) async throws {
    let view = proofs.webView
    guard view.canGoBack, let here = view.url else {
      Clock.log("soak history: there is no page to go back to")
      return
    }
    monitor.expectFrames(every: nil)
    view.goBack()
    try await proofs.waitUntil("the page before is shown", timeout: 30) {
      view.url != here && !view.isLoading
    }
    try await proofs.settle(seconds)
    view.goForward()
    try await proofs.waitUntil("the page comes back", timeout: 30) {
      view.url == here && !view.isLoading && view.title == self.page.title
    }
    try await proofs.settle(0.5)
    try await takeStock()
    try await shown()
  }

  /// Changes the window's size many times a second, as dragging its edge does, and puts it back.
  func resize(_ seconds: Double) async throws {
    let original = window.frame
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    var turn = 0
    while ContinuousClock.now < deadline {
      let grow = CGFloat((turn * 37) % 220)
      var frame = original
      frame.size.width += grow
      frame.size.height += grow / 2
      frame.origin.y -= grow / 2
      window.setFrame(frame, display: true)
      turn += 1
      try await Task.sleep(for: .milliseconds(16 + (turn * 13) % 50))
    }
    window.setFrame(original, display: true)
    Clock.log("soak resize: \(turn) sizes")
    try await shown()
  }
}
