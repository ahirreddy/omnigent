internal import AppKit
internal import Foundation
internal import OmnigentBrowser
internal import OmnigentWebLayer

/// Restore across a real quit and relaunch: the first app saves its tabs, shuts Chromium down
/// and relaunches itself with `restore-verify`, which restores them lazily and walks history.
extension Proofs {
  // MARK: Restore across quit and relaunch

  func restoreAcrossRelaunch() async throws {
    let server = try await proofServer()
    let port = server.port
    let directory =
      model.options.browserDirectory
      ?? outputDirectory.appending(path: "browser2-restore-state", directoryHint: .isDirectory)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    let harness = try await tabHarness("restore (before quit)", directory: directory)
    let environment = harness.environment
    let base = server.base
    let work = try environment.profiles.create(name: "Work", color: .green, avatar: .emoji("🦉"))
    let main = harness.add(environment.makeTab(url: try url("\(base)/page/nav-one")))
    try await waitModel(main, title: "Nav One")
    for (name, title) in [("nav-two", "Nav Two"), ("nav-three", "Nav Three")] {
      main.load(try url("\(base)/page/\(name)"))
      try await waitModel(main, title: title)
    }
    let pinned = harness.add(
      environment.makeTab(profileID: work.id, url: try url("\(base)/page/nav-one")))
    try await waitModel(pinned, title: "Nav One")
    pinned.isPinned = true
    pinned.toggleMute()
    harness.selectedID = main.id
    try await waitUntil("favicons", timeout: 10) { main.favicon != nil && pinned.favicon != nil }
    try await shootBrowser(harness.window, "restore-before-quit")
    let snapshot = harness.snapshot()
    let file = BrowserPersistentFile<BrowserSessionSnapshot>(
      url: directory.appending(path: "session.json"), version: 1)
    try file.write(snapshot)
    try environment.flush()
    Clock.log(
      "restore: saved \(snapshot.tabs.count) tabs; main history \(snapshot.tabs[0].history.entries.map(\.title))"
    )
    harness.window.close()
    server.stop()
    self.server = nil
    model.session.shutdown()
    let status = try await relaunch([
      "--proof", "restore-verify", "--engine", engine.rawValue, "--render-mode", modeName,
      "--browser-dir", directory.path, "--server-port", "\(port)", "--output", outputDirectory.path,
    ])
    guard status == 0 else { throw ProofFailure("The relaunched app failed restore (\(status)).") }
    Clock.log("restore: the relaunched app restored the tabs and their history")
  }

  private func relaunch(_ arguments: [String]) async throws -> Int32 {
    guard let executable = Bundle.main.executableURL else {
      throw ProofFailure("No executable to relaunch.")
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    try process.run()
    Clock.log("relaunched \(executable.lastPathComponent) as pid \(process.processIdentifier)")
    while process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
    return process.terminationStatus
  }

  func restoreVerify() async throws {
    guard let directory = model.options.browserDirectory else {
      throw ProofFailure("restore-verify needs --browser-dir.")
    }
    let file = BrowserPersistentFile<BrowserSessionSnapshot>(
      url: directory.appending(path: "session.json"), version: 1)
    guard let snapshot = try file.load() else { throw ProofFailure("No saved session.") }
    _ = try await proofServer()
    let harness = try await tabHarness("restore (after relaunch)", directory: directory)
    defer { harness.tearDown() }
    let environment = harness.environment
    let models = snapshot.tabs.map { environment.restoreTab($0) }
    for model in models { harness.add(model, select: false) }
    harness.selectedID = nil
    let titles = models.map(\.title)
    let lazy = models.allSatisfy { !$0.isActivated }
    Clock.log(
      "restore-verify: tabs \(titles), lazy \(lazy), profiles \(models.map { $0.profile?.name ?? "-" })"
    )
    guard titles == ["Nav Three", "Nav One"], lazy, models[1].isPinned, models[1].isMuted,
      models[1].profile?.name == "Work", models.allSatisfy({ $0.favicon != nil })
    else {
      throw ProofFailure("Restored tabs lost their title, profile, pin, mute or favicon.")
    }
    try await shootBrowser(harness.window, "restore-lazy")
    let main = models[0]
    harness.selectedID = snapshot.selectedTabID
    try await waitModel(main, title: "Nav Three")
    try await waitUntil("back history", timeout: 10) { main.canGoBack }
    guard !models[1].isActivated else { throw ProofFailure("A background tab loaded early.") }
    try await shootBrowser(harness.window, "restore-after-relaunch")
    main.goBack()
    try await waitModel(main, title: "Nav Two")
    main.goBack()
    try await waitModel(main, title: "Nav One")
    main.goForward()
    try await waitModel(main, title: "Nav Two")
    try await shootBrowser(harness.window, "restore-back")
    harness.selectedID = models[1].id
    try await waitModel(models[1], title: "Nav One")
    try await waitUntil("mute restored", timeout: 5) { models[1].tab?.state.isMuted == true }
    Clock.log("restore-verify: back to Nav Two and Nav One, forward to Nav Two; pinned tab muted")
  }
}
