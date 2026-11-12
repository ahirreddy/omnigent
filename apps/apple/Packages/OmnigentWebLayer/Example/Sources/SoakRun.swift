internal import AppKit
internal import Foundation
internal import OmnigentWebLayer

/// Carries out the soak's steps: loads its pages, sends them input the way a person would, and
/// takes the window away and brings it back.
final class SoakRun {
  let proofs: Proofs
  let monitor: SoakMonitor
  let window: NSWindow
  private(set) var page = SoakPage.all[0]
  private var points: [String: CGPoint] = [:]
  /// Inputs the page must have counted since it loaded, and what it had counted at last look.
  private var sentInputs = 0
  private var handledInputs = 0
  private var sentKeys = 0
  private var actions = 0
  private var wheelSteps = 0
  private var loads = 0

  private static let selectors = [
    "animation": ["#tap"], "timers": ["#tap"], "document": ["#result"], "form": ["#name", "#send"],
    "app": ["#nav-home", "#nav-list", "#nav-detail", "#nav-settings", "#card"],
  ]

  /// What each kind of step does for its seconds; a page step loads instead.
  private static let actions: [SoakStep.Kind: (SoakRun) -> (Double) async throws -> Void] = [
    .active: { $0.active }, .idle: { $0.idle }, .cover: { $0.cover }, .minimize: { $0.minimize },
    .hide: { $0.hide }, .detach: { $0.detach }, .flap: { $0.flap }, .resize: { $0.resize },
    .history: { $0.history }, .offscreen: { $0.offscreen }, .crowd: { $0.crowd },
  ]

  init(proofs: Proofs, monitor: SoakMonitor, window: NSWindow) {
    self.proofs = proofs
    self.monitor = monitor
    self.window = window
  }

  /// Runs one step and logs what it measured. A step that throws is a failure of the soak, and
  /// the next step still runs.
  func perform(_ step: SoakStep, index: Int) async {
    monitor.step = "\(index + 1) \(step.text) on \(page.name)"
    let frames = monitor.frames
    let drops = monitor.drops
    let failures = monitor.failures.count
    let began = ContinuousClock.now
    let scriptFrames = await animationFrames()
    do {
      if step.kind == .page {
        try await load(step.page)
      } else if let action = Self.actions[step.kind] {
        try await action(self)(step.seconds)
      } else {
        throw ProofFailure("The soak does not know how to do '\(step.text)'.")
      }
      try await checkShownState()
    } catch {
      monitor.fail("the step ended with an error: \(error)")
    }
    let seconds = SoakMonitor.milliseconds(.now - began) / 1000
    let added = monitor.frames - frames
    if let before = scriptFrames, let after = await animationFrames(), after >= before {
      // The page's own count of animation frames, next to the frames that were presented.
      let rate = Int((after - before) / max(seconds, 0.001))
      Clock.log("soak page: \(rate) animation frames a second")
    }
    Clock.log(
      "soak step \(monitor.step): \(Int(seconds)) s, frames +\(added) "
        + "(\(Int(Double(added) / max(seconds, 0.001))) fps), drops +\(monitor.drops - drops), "
        + "failures +\(monitor.failures.count - failures)")
  }

  /// The animation page's count of the frames its script drew; nil on other pages, or when
  /// the page cannot be asked, which the step's own checks report as a failure.
  private func animationFrames() async -> Double? {
    guard page.name == "animation", loads > 0 else { return nil }
    do {
      return try await proofs.number("window.soak.frames")
    } catch {
      Clock.log("soak page: the animation's frame count could not be read: \(error)")
      return nil
    }
  }

  private func load(_ name: String) async throws {
    guard let next = SoakPage.all.first(where: { $0.name == name }) else {
      throw ProofFailure("Unknown soak page '\(name)'.")
    }
    monitor.expectFrames(every: nil)
    page = next
    // Every other page comes from another site, so Chromium changes renderer processes.
    loads += 1
    let host = loads.isMultiple(of: 2) ? "localhost" : "127.0.0.1"
    let port = try await proofs.proofServer().port
    try await proofs.load(
      URL(string: "http://\(host):\(port)/page/soak-\(name)"), title: next.title)
    try await proofs.settle(0.5)
    wheelSteps = 0
    try await takeStock()
    monitor.expectFrames(every: next.frameInterval)
  }

  /// Finds the page's controls and what it has counted so far: a page that history brings
  /// back may be as it was left, or loaded afresh.
  func takeStock() async throws {
    points = [:]
    for selector in Self.selectors[page.name] ?? [] {
      points[selector] = try await proofs.center(of: selector)
    }
    sentInputs = Int(try await proofs.number("window.soak.inputs"))
    handledInputs = sentInputs
    sentKeys = page.name == "form" ? Int(try await proofs.number("window.soak.typed")) : 0
  }

  private func idle(_ seconds: Double) async throws {
    try await proofs.settle(seconds)
  }

  // MARK: Input

  func active(_ seconds: Double) async throws {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
      try await act()
      actions += 1
      // People pause between actions: 60 to 300 ms here.
      try await Task.sleep(for: .milliseconds(60 + (actions * 37) % 240))
    }
    try await checkPageAnswered()
  }

  private func point(_ selector: String) throws -> CGPoint {
    guard let point = points[selector] else {
      throw ProofFailure("The soak has no place for \(selector) on \(page.name).")
    }
    return point
  }

  private func clickInput(_ selector: String) async throws {
    let place = try point(selector)
    try await monitor.input("a click") { self.proofs.click(at: place) }
  }

  /// One thing a person does with the page on screen.
  private func act() async throws {
    switch page.name {
    case "document":
      // Down for 25 steps, then back up, so the page never sits at an end.
      let down = (wheelSteps / 25).isMultiple(of: 2)
      wheelSteps += 1
      let place = CGPoint(x: 300, y: 300)
      try await monitor.input("a wheel step") {
        try self.proofs.webView.renderer.agentScroll(
          at: place, deltaX: 0, deltaY: down ? -120 : 120)
      }
    case "app":
      if actions % 5 == 4 {
        // A short drag of the card; the clicks after it show the page still takes input.
        try await proofs.dragAndLetGo(from: try point("#card"), distance: 30, holdMilliseconds: 0)
        try await proofs.settle(0.2)
      }
      try await clickInput(["#nav-home", "#nav-list", "#nav-detail", "#nav-settings"][actions % 4])
      sentInputs += 1
    case "form":
      try await clickInput("#name")
      for character in "soak" {
        try await monitor.input("a key") {
          self.proofs.key(
            keyCode: Proofs.keyCodes[character] ?? 0, characters: String(character))
        }
        sentKeys += 1
        try await Task.sleep(for: .milliseconds(40))
      }
      try await clickInput("#send")
      sentInputs += 1
    default:
      try await clickInput("#tap")
      sentInputs += 1
    }
  }

  /// Frames say the page drew; this asks whether its script handled what was sent.
  private func checkPageAnswered() async throws {
    try await proofs.settle(0.3)
    let handled = Int(try await proofs.number("window.soak.inputs"))
    if page.name == "document" {
      if handled <= handledInputs { monitor.fail("the document did not scroll") }
    } else if handled != sentInputs {
      monitor.fail("the page handled \(handled) of \(sentInputs) inputs")
    }
    handledInputs = handled
    if page.name == "form" {
      let typed = Int(try await proofs.number("window.soak.typed"))
      if typed != sentKeys { monitor.fail("the form took \(typed) of \(sentKeys) keys") }
    }
  }
}
