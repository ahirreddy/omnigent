internal import AppKit
internal import CoreGraphics
internal import Foundation
internal import OmnigentBrowser
internal import OmnigentWebLayer

/// Browsing proofs through `BrowserTabModel` and `BrowserTabContentView`, on the engine
/// `--engine` picks: profiles with isolated cookies, find, zoom, DevTools, favicons, audio,
/// view source, reopen closed tab, and restore across a real quit and relaunch.
extension Proofs {
  static let browsing = ["profiles", "browsing", "reopen", "restore"]

  func tabHarness(_ title: String, directory: URL? = nil) async throws -> BrowserTabHarness {
    if engine == .chromium { try await model.session.waitUntilReady() }
    let folder =
      directory
      ?? FileManager.default.temporaryDirectory.appending(
        path: "browser2-\(UUID().uuidString)", directoryHint: .isDirectory)
    return try BrowserTabHarness(
      kind: engine, provider: provider, directory: folder,
      title: "Browser tabs: \(title) (\(engine.displayName))")
  }

  func waitModel(_ model: BrowserTabModel, title: String, timeout: Double = 30) async throws {
    try await Task.sleep(for: .milliseconds(150))
    do {
      try await waitUntil("tab model shows '\(title)'", timeout: timeout) {
        if let error = model.pageError, !error.isCancellation { return true }
        return model.tab != nil && !model.isLoading && model.title == title
      }
    } catch {
      let state = model.tab?.state
      Clock.log(
        "model state: url \(model.url?.absoluteString ?? "-") engine url \(state?.url?.absoluteString ?? "-") loading \(model.isLoading)/\(state?.isLoading ?? false) title '\(model.title)' error \(String(describing: model.lastError)) page \(String(describing: model.pageError))"
      )
      throw error
    }
    if let error = model.pageError, !error.isCancellation { throw error }
  }

  func liveTab(_ model: BrowserTabModel) throws -> any BrowserTab {
    guard let tab = model.tab else { throw ProofFailure("The model has no engine tab.") }
    return tab
  }

  /// Captures one window as `browser2-<name>-<engine>.png`.
  @discardableResult
  func shootBrowser(_ window: NSWindow, _ name: String, area: Bool = false) async throws -> URL {
    let url = outputDirectory.appending(path: "browser2-\(name)-\(engineSuffix).png")
    var arguments = ["-x", "-o"]
    if area {
      let frame = window.frame
      let top = NSScreen.screens.first?.frame.maxY ?? frame.maxY
      arguments.append(
        "-R\(Int(frame.minX)),\(Int(top - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))")
    } else {
      arguments.append("-l\(window.windowNumber)")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = arguments + [url.path]
    try process.run()
    while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    guard process.terminationStatus == 0 else {
      throw ProofFailure("screencapture failed with status \(process.terminationStatus)")
    }
    Clock.log("screenshot \(url.path)")
    return url
  }

  /// A key chord sent to `window` as AppKit would deliver it.
  func chord(
    _ window: NSWindow, keyCode: UInt16, _ characters: String,
    _ modifiers: NSEvent.ModifierFlags = .command
  ) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard
        let event = NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: modifiers,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, characters: characters, charactersIgnoringModifiers: characters,
          isARepeat: false, keyCode: keyCode)
      else {
        continue
      }
      NSApp.sendEvent(event)
    }
  }

  // MARK: Profiles

  func browserProfiles() async throws {
    let base = try await proofServer().base
    let harness = try await tabHarness("profiles")
    let environment = harness.environment
    defer { harness.tearDown() }
    let personal = environment.profiles.defaultProfile
    let work = try environment.profiles.create(
      name: "Work", color: .orange, avatar: .symbol("briefcase.fill"))
    let first = harness.add(
      environment.makeTab(profileID: personal.id, url: try url("\(base)/set?v=alpha")))
    try await waitModel(first, title: "set")
    first.load(try url("\(base)/read"))
    try await waitModel(first, title: "read")
    let firstCookie = try await text(try liveTab(first))
    let second = harness.add(
      environment.makeTab(profileID: work.id, url: try url("\(base)/read")))
    try await waitModel(second, title: "read")
    let secondBefore = try await text(try liveTab(second))
    second.load(try url("\(base)/set?v=beta"))
    try await waitModel(second, title: "set")
    second.load(try url("\(base)/read"))
    try await waitModel(second, title: "read")
    let secondAfter = try await text(try liveTab(second))
    try await settle(0.4)
    try await shootBrowser(harness.window, "profiles-work")
    harness.selectedID = first.id
    try await settle(0.3)
    first.reload()
    try await waitModel(first, title: "read")
    let firstAfter = try await text(try liveTab(first))
    try await shootBrowser(harness.window, "profiles-personal")
    Clock.log(
      "profiles: \(personal.name) \(firstCookie) -> \(firstAfter); \(work.name) \(secondBefore) -> \(secondAfter)"
    )
    guard firstCookie == "cookie: owl=alpha", secondBefore == "cookie: (none)",
      secondAfter == "cookie: owl=beta", firstAfter == "cookie: owl=alpha"
    else {
      throw ProofFailure("Cookies leaked between browser profiles.")
    }
    guard first.browserProfile != second.browserProfile,
      second.profile?.name == "Work", first.profile?.id == personal.id
    else {
      throw ProofFailure("Tabs did not keep their profiles.")
    }
    harness.close(first)
    harness.close(second)
    try await environment.profiles.delete(id: work.id)
    try await environment.provider.deleteProfileData(personal.browserProfile)
  }

  // MARK: Find, zoom, DevTools, favicon, audio, view source, omnibox

  func browsingEssentials() async throws {
    let base = try await proofServer().base
    let harness = try await tabHarness("essentials")
    let environment = harness.environment
    defer { harness.tearDown() }
    let window = harness.window
    let page = harness.add(environment.makeTab(url: try url("\(base)/page/find")))
    try await waitModel(page, title: "OWL find")
    try await waitUntil("favicon", timeout: 10) { page.favicon != nil }
    Clock.log("favicon: \(page.favicon?.pngData.count ?? 0) bytes")

    // Find, opened with Command-F while the page has focus.
    try await userClick(try liveTab(page), "#result", in: window)
    try await settle(0.3)
    chord(window, keyCode: 3, "f")
    try await waitUntil("find bar from Command-F", timeout: 5) { page.find.isVisible }
    page.find.query = "owl"
    await page.findNext()
    let found = try await waitFor("find result") { page.find.result }
    Clock.log("find 'owl': \(found)")
    guard found.matchFound, engine == .system || found.matchCount == 6 else {
      throw ProofFailure("Find reported \(found); the page has 6 matches.")
    }
    try await settle(0.3)
    try await shootBrowser(window, "find")
    page.hideFindBar()

    try await zoom(page, harness: harness, base: base)
    try await devTools(page, window: window)
    try await audio(page, harness: harness, base: base)
    try await viewSource(page, harness: harness)
    try await omnibox(page, harness: harness)
  }

  private func zoom(_ page: BrowserTabModel, harness: BrowserTabHarness, base: String)
    async throws
  {
    let environment = harness.environment
    let window = harness.window
    // Zoom with Command-=, remembered for the site.
    let tab = try liveTab(page)
    let widthBefore = try await eval(tab, "window.innerWidth").numberValue ?? 0
    chord(window, keyCode: 24, "=")
    try await waitUntil("zoom 110%", timeout: 5) { abs(page.zoomFactor - 1.1) < 0.001 }
    try await settle(0.5)
    let widthAfter = try await eval(tab, "window.innerWidth").numberValue ?? 0
    Clock.log("zoom: \(page.zoomFactor); innerWidth \(widthBefore) -> \(widthAfter)")
    guard widthAfter < widthBefore * 0.95 else {
      throw ProofFailure("Zooming did not change the page's CSS width.")
    }
    try await shootBrowser(window, "zoom")
    let sameSite = harness.add(environment.makeTab(url: try url("\(base)/page/nav-one")))
    try await waitModel(sameSite, title: "Nav One")
    try await waitUntil("site zoom applied", timeout: 5) { abs(sameSite.zoomFactor - 1.1) < 0.001 }
    let otherSite = harness.add(
      environment.makeTab(
        url: try url(
          base.replacingOccurrences(of: "127.0.0.1", with: "localhost") + "/page/nav-one")))
    try await waitModel(otherSite, title: "Nav One")
    Clock.log("zoom memory: same site \(sameSite.zoomFactor), other host \(otherSite.zoomFactor)")
    guard abs(otherSite.zoomFactor - 1) < 0.001 else {
      throw ProofFailure("Zoom leaked to another host.")
    }
    harness.close(otherSite)
    harness.close(sameSite)
    harness.selectedID = page.id
    try await settle(0.3)
    chord(window, keyCode: 29, "0")
    try await waitUntil("zoom reset", timeout: 5) { abs(page.zoomFactor - 1) < 0.001 }
  }

  private func devTools(_ page: BrowserTabModel, window: NSWindow) async throws {
    chord(window, keyCode: 34, "i", [.command, .option])
    if engine == .system {
      try await waitUntil("WebKit DevTools refusal", timeout: 5) { page.lastError != nil }
      Clock.log("DevTools on WebKit: \(page.lastError?.localizedDescription ?? "-")")
      page.dismissError()
      return
    }
    guard let pid = model.session.hostInfo?.pid else { throw ProofFailure("No host pid.") }
    var windows = 0
    try await waitUntil("a DevTools window in the host", timeout: 10) {
      windows = Self.windowCount(pid: pid)
      return windows > 0
    }
    try await settle(1.5)
    Clock.log("DevTools: \(windows) host window(s) after Option-Command-I")
    let devToolsShot = outputDirectory.appending(path: "browser2-devtools-\(engineSuffix).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", devToolsShot.path]
    try process.run()
    process.waitUntilExit()
    Clock.log("screenshot \(devToolsShot.path)")
  }

  static func windowCount(pid: pid_t) -> Int {
    guard
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]]
    else {
      return 0
    }
    return list.filter {
      ($0[kCGWindowOwnerPID as String] as? Int32) == pid
        && ($0[kCGWindowLayer as String] as? Int) == 0
    }.count
  }

  private func audio(_ page: BrowserTabModel, harness: BrowserTabHarness, base: String) async throws
  {
    page.load(try url("\(base)/page/audio"))
    try await waitModel(page, title: "OWL audio")
    let tab = try liveTab(page)
    try await eval(tab, "playTone(); true")
    _ = try await waitText(tab, { $0 == "playing" || $0.hasPrefix("error") }, "tone playing")
    try await waitUntil("audible", timeout: 10) { page.isAudible }
    page.toggleMute()
    try await waitUntil("muted", timeout: 5) { tab.state.isMuted && page.isMuted }
    try await settle(0.4)
    try await shootBrowser(harness.window, "audio-muted")
    Clock.log("audio: audible \(page.isAudible), muted \(page.isMuted)")
    page.toggleMute()
    try await eval(tab, "document.querySelector('#tone').pause(); true")
    try await waitUntil("silent", timeout: 10) { !page.isAudible }
  }

  private func viewSource(_ page: BrowserTabModel, harness: BrowserTabHarness) async throws {
    let before = harness.tabs.count
    page.viewSource()
    try await waitUntil("a view-source tab", timeout: 10) { harness.tabs.count == before + 1 }
    let source = try harness.requireSelected()
    try await waitUntil("source loaded", timeout: 20) {
      source.tab != nil && !source.isLoading && source.url != nil
    }
    try await settle(0.6)
    Clock.log(
      "view source: \(source.url?.absoluteString.prefix(60) ?? "-") '\(source.title.prefix(60))'")
    // Chromium reports the inner URL of a view-source page and titles it "view-source:…".
    let scheme = source.url?.scheme
    guard scheme == "view-source" || scheme == "data" || source.title.hasPrefix("view-source:")
    else {
      throw ProofFailure("View Source opened \(source.url?.absoluteString ?? "nothing").")
    }
    try await shootBrowser(harness.window, "view-source")
    harness.close(source)
    harness.selectedID = page.id
  }

  private func omnibox(_ page: BrowserTabModel, harness: BrowserTabHarness) async throws {
    try await settle(0.4)
    page.focusOmnibox()
    try await settle(0.4)
    chord(harness.window, keyCode: 0, "a", .command)  // Select all, then type over it.
    for (keyCode, character) in [(UInt16(45), "n"), (0, "a"), (9, "v")] {
      chord(harness.window, keyCode: keyCode, character, [])
    }
    try await settle(0.6)
    try await shootBrowser(harness.window, "omnibox")
    chord(harness.window, keyCode: 53, "\u{1b}", [])
  }

  // MARK: Reopen closed tab

  func reopenClosedTab() async throws {
    let base = try await proofServer().base
    let harness = try await tabHarness("reopen")
    let environment = harness.environment
    defer { harness.tearDown() }
    let model = harness.add(environment.makeTab(url: try url("\(base)/page/nav-one")))
    try await waitModel(model, title: "Nav One")
    model.load(try url("\(base)/page/nav-two"))
    try await waitModel(model, title: "Nav Two")
    let state = harness.close(model)
    guard environment.recentlyClosed.states.last?.id == state.id, state.history.entries.count == 2
    else {
      throw ProofFailure("The closed tab was not recorded with its history: \(state.history)")
    }
    guard let reopened = environment.reopenClosedTab() else {
      throw ProofFailure("Nothing to reopen.")
    }
    harness.add(reopened)
    try await waitModel(reopened, title: "Nav Two")
    try await waitUntil("back history after reopen", timeout: 10) { reopened.canGoBack }
    reopened.goBack()
    try await waitModel(reopened, title: "Nav One")
    try await shootBrowser(harness.window, "reopen")
    Clock.log("reopen: \(reopened.id == state.id ? "same tab ID" : "new ID"), back reached Nav One")
  }
}
