internal import AppKit
internal import Foundation
internal import OmnigentBrowser
internal import OmnigentWebLayer
internal import SwiftUI

/// Protocol 1.1 proofs through the shared UI: native sheets, panels, interstitials and popup
/// windows, on the engine `--engine` picks.
extension Proofs {
  func dialogs() async throws {
    let (harness, tab) = try await harness(try await pageURL("dialogs"), title: "OWL dialogs")
    defer { harness.close() }
    try await eval(tab, "setTimeout(runAlert, 0)")
    let alert = try await waitFor("alert sheet") { harness.presenter.presentedAlert }
    try await settle(0.5)
    try await shoot(harness.window, "dialog-alert")
    alert.buttons[0].performClick(nil)
    _ = try await waitText(tab, { $0 == "alert:done" }, "alert answered")
    try await eval(tab, "setTimeout(runConfirm, 0)")
    let confirm = try await waitFor("confirm sheet") { harness.presenter.presentedAlert }
    try await settle(0.3)
    try await shoot(harness.window, "dialog-confirm")
    confirm.buttons[1].performClick(nil)
    _ = try await waitText(tab, { $0 == "confirm:false" }, "confirm cancelled")
    try await eval(tab, "setTimeout(runPrompt, 0)")
    let prompt = try await waitFor("prompt sheet") { harness.presenter.presentedAlert }
    (prompt.accessoryView as? NSTextField)?.stringValue = "owl answer"
    try await settle(0.3)
    try await shoot(harness.window, "dialog-prompt")
    prompt.buttons[0].performClick(nil)
    _ = try await waitText(tab, { $0 == "prompt:owl answer" }, "prompt answered")
    Clock.log(
      "dialogs: alert, confirm (Cancel -> false) and prompt ('owl answer') answered natively")
    if skipOnWebKit("WKWebView has no public beforeunload dialog API") { return }
    try await userClick(tab, "#arm", in: harness.window)  // A user gesture arms beforeunload.
    _ = try await waitText(tab, { $0 == "armed" }, "beforeunload armed")
    let start = tab.state.url
    tab.load(try await pageURL("file"))
    let leave = try await waitFor("beforeunload sheet") { harness.presenter.presentedAlert }
    try await settle(0.3)
    try await shoot(harness.window, "dialog-beforeunload")
    leave.buttons[1].performClick(nil)
    try await settle(0.6)
    guard tab.state.url == start else { throw ProofFailure("Stay did not keep the page.") }
    Clock.log("beforeunload: 'Stay' kept \(start?.absoluteString ?? "-")")
  }

  func permissions() async throws {
    if skipOnWebKit("camera prompts need camera usage strings in the app's Info.plist") { return }
    let profile = BrowserProfile(identifier: "owl2-permissions-\(UUID())", persistence: .persistent)
    let (harness, tab) = try await harness(
      try await pageURL("permissions"), title: "OWL permissions", profile: profile)
    defer {
      harness.presenter.permissionStore.reset(profile: profile)
      harness.close()
    }
    try await eval(tab, "askCamera()")
    let alert = try await waitFor("camera permission sheet") { harness.presenter.presentedAlert }
    try await settle(0.4)
    try await shoot(harness.window, "permission-camera")
    alert.buttons[1].performClick(nil)  // Don't Allow, remembered.
    _ = try await waitText(tab, { $0 == "camera:NotAllowedError" }, "camera denied")
    let origin = try await proofServer().base
    let stored = harness.presenter.permissionStore.decision(
      for: .camera, origin: origin, profile: profile)
    let persisted = harness.defaults.dictionary(
      forKey: BrowserPermissionStore.defaultsKeyPrefix + profile.storageKey)
    Clock.log(
      "camera decision stored: \(String(describing: stored)); persisted: \(persisted ?? [:])")
    guard stored == .deny, persisted != nil else {
      throw ProofFailure("The camera decision was not persisted for the persistent profile.")
    }
    try await eval(tab, "document.querySelector('#result').textContent = 'retry'; askCamera()")
    _ = try await waitText(tab, { $0 == "camera:NotAllowedError" }, "remembered deny")
    guard harness.presenter.presentedAlert == nil else {
      throw ProofFailure("A remembered decision asked again.")
    }
    try await eval(tab, "askNotifications()")
    // Chromium may answer notifications itself; poll briefly instead of failing on a timeout.
    let deadline = ContinuousClock.now + .seconds(4)
    while harness.presenter.presentedAlert == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    if let notifications = harness.presenter.presentedAlert {
      try await shoot(harness.window, "permission-notifications")
      notifications.buttons[0].performClick(nil)
      let result = try await waitText(tab, { $0.hasPrefix("notifications:") }, "notifications")
      Clock.log("notifications prompt answered Allow: \(result)")
    } else {
      Clock.log("notifications: Chromium answered without a prompt: \(try await text(tab))")
    }
    try await ephemeralPermission()
  }

  private func ephemeralPermission() async throws {
    let profile = BrowserProfile.ephemeral("owl2-permissions-ephemeral-\(UUID())")
    let (harness, tab) = try await harness(
      try await pageURL("permissions"), title: "OWL permissions", profile: profile)
    defer { harness.close() }
    try await eval(tab, "askCamera()")
    let alert = try await waitFor("ephemeral camera sheet") { harness.presenter.presentedAlert }
    alert.buttons[1].performClick(nil)
    _ = try await waitText(tab, { $0 == "camera:NotAllowedError" }, "ephemeral deny")
    let inMemory = harness.presenter.permissionStore.decisions(for: profile)
    let persisted = harness.defaults.dictionary(
      forKey: BrowserPermissionStore.defaultsKeyPrefix + profile.storageKey)
    Clock.log(
      "ephemeral profile: in memory \(inMemory), persisted \(String(describing: persisted))")
    guard !inMemory.isEmpty, persisted == nil else {
      throw ProofFailure("Ephemeral decisions must stay in memory only.")
    }
  }

  func files() async throws {
    let (harness, tab) = try await harness(try await pageURL("file"), title: "OWL file")
    defer { harness.close() }
    let first = FileManager.default.temporaryDirectory.appending(path: "owl2-alpha.txt")
    let second = FileManager.default.temporaryDirectory.appending(path: "owl2-beta.txt")
    try Data("alpha".utf8).write(to: first)
    try Data("beta".utf8).write(to: second)
    try await userClick(tab, "#file", in: harness.window)
    let panel = try await waitFor("open panel") { harness.presenter.presentedPanel }
    try await settle(0.8)
    try await shoot(harness.window, "file-chooser")
    guard case .fileChooser(let chooser) = pendingPrompt(tab, "file_chooser") else {
      throw ProofFailure("No file chooser prompt is pending.")
    }
    Clock.log("file chooser: mode \(chooser.mode), extensions \(chooser.allowedExtensions)")
    chooser.choose([first, second])  // What the user picks in the panel.
    panel.cancel(nil)
    let result = try await waitText(tab, { $0.contains("owl2-beta.txt=beta") }, "files chosen")
    Clock.log("page read the chosen files: \(result)")
  }

  func downloads() async throws {
    let (harness, tab) = try await harness(try await pageURL("download"), title: "OWL download")
    defer { harness.close() }
    harness.presenter.downloadSettings.askBeforeDownload = true
    try await userClick(tab, "#link", in: harness.window)
    let panel = try await waitFor("save panel", timeout: 15) { harness.presenter.presentedPanel }
    try await settle(0.8)
    try await shoot(harness.window, "download-ask")
    guard case .download(let request) = pendingPrompt(tab, "download") else {
      throw ProofFailure("No download prompt is pending.")
    }
    let asked = harness.downloadDirectory.appending(path: "owl2-asked.txt")
    request.save(to: asked)
    panel.cancel(nil)
    try await waitUntil("asked download completes", timeout: 20) {
      harness.downloads.items.first?.state == .complete
    }
    harness.presenter.downloadSettings.askBeforeDownload = false
    try await userClick(tab, "#link", in: harness.window)
    try await waitUntil("automatic download completes", timeout: 20) {
      harness.downloads.items.count == 2
        && harness.downloads.items.allSatisfy { $0.state == .complete }
    }
    let automatic = harness.downloadDirectory.appending(path: "owl2-proof-download.txt")
    for file in [asked, automatic] {
      let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
      Clock.log("download \(file.lastPathComponent): \(size) bytes")
      guard size == ProofServer.downloadSize else {
        throw ProofFailure("\(file.path) is \(size) bytes.")
      }
    }
    let list = NSWindow(
      contentRect: NSRect(x: 120, y: 120, width: 420, height: 320), styleMask: [.titled],
      backing: .buffered, defer: false)
    list.title = "Downloads"
    list.isReleasedWhenClosed = false
    list.level = .floating
    list.contentView = NSHostingView(
      rootView: BrowserDownloadsView(
        center: harness.downloads, settings: harness.presenter.downloadSettings))
    list.makeKeyAndOrderFront(nil)
    defer { list.close() }
    try await settle(0.6)
    try await shoot(list, "downloads-list")
  }

  func authentication() async throws {
    let base = try await proofServer().base
    let (harness, tab) = try await harness(try await pageURL("download"), title: "OWL download")
    defer { harness.close() }
    tab.load(try url("\(base)/auth"))
    let alert: NSAlert
    do {
      alert = try await waitFor("auth sheet", timeout: 15) { harness.presenter.presentedAlert }
    } catch {
      Clock.log(
        "auth sheet missing: url \(tab.state.url?.absoluteString ?? "-") title '\(tab.state.title)' error \(String(describing: tab.state.lastError))"
      )
      try await shoot(harness.window, "auth-missing")
      throw error
    }
    guard let stack = alert.accessoryView as? NSStackView, stack.arrangedSubviews.count == 3,
      let user = stack.arrangedSubviews[0] as? NSTextField,
      let password = stack.arrangedSubviews[1] as? NSSecureTextField
    else {
      throw ProofFailure("The credential sheet has no user name and password fields.")
    }
    user.stringValue = "owl"
    password.stringValue = "secret"
    try await settle(0.4)
    try await shoot(harness.window, "auth-sheet")
    alert.buttons[0].performClick(nil)
    try await waitForTab(tab, title: "authorized")
    let result = try await text(tab)
    let space = BrowserProtectionSpace(
      host: "127.0.0.1", port: Int(try await proofServer().port), realm: "OWL Proof",
      scheme: "basic", isProxy: false, isSecure: false)
    let stored = harness.credentials.credential(for: space)
    Clock.log(
      "auth: page says '\(result)'; stored without opt-in: \(stored == nil ? "nothing" : "a credential")"
    )
    guard result == "authorized as owl", stored == nil else {
      throw ProofFailure("HTTP auth failed or stored a password without opt-in.")
    }
  }

  func certificates() async throws {
    let server = try SelfSignedTLSServer(directory: FileManager.default.temporaryDirectory)
    defer { server.stop() }
    try await settle(0.8)
    let (harness, tab) = try await harness(server.url, title: nil)
    defer { harness.close() }
    let prompt = try await waitFor("certificate interstitial", timeout: 15) {
      harness.presenter.interstitial(for: tab)
    }
    Clock.log(
      "certificate error: \(prompt.errorCode) '\(prompt.message)' subject '\(prompt.subject)' overridable \(prompt.isOverridable)"
    )
    try await settle(0.6)
    try await shoot(harness.window, "certificate-interstitial")
    harness.presenter.resolveInterstitial(for: tab, proceed: true)
    do {
      try await waitUntil("page loads after proceeding", timeout: 20) {
        !tab.state.isLoading && harness.presenter.interstitial(for: tab) == nil
          && tab.state.url?.host == "127.0.0.1"
      }
    } catch {
      Clock.log(
        "after proceeding: url \(tab.state.url?.absoluteString ?? "-") loading \(tab.state.isLoading) error \(String(describing: tab.state.lastError)) prompts \(tab.state.pendingPrompts.map(\.kindName))"
      )
      throw error
    }
    try await settle(1)
    let body = try await text(tab)
    Clock.log("after proceeding the page shows: \(body)")
    guard body == "self-signed page loaded" else { throw ProofFailure("Wrong page: \(body)") }
    try await shoot(harness.window, "certificate-proceeded")
  }

  func popups() async throws {
    // A persistent profile: Chromium's own blocker stays on in incognito contexts and would drop
    // the gesture-less open before the popup policy sees it.
    let (harness, tab) = try await harness(
      try await pageURL("popup"), title: "OWL popup",
      profile: BrowserProfile(identifier: "owl2-popups", persistence: .persistent))
    defer { harness.close() }
    if !skipOnWebKit("WebKit blocks gesture-less popups itself and reports nothing") {
      let blocked = try await waitFor("blocked popup notice") { tab.state.lastBlockedPopup }
      Clock.log(
        "blocked without a gesture: \(blocked.url?.absoluteString ?? "-") (\(blocked.reason))")
      try await settle(0.4)
      try await shoot(harness.window, "popup-blocked")
    }
    try await userClick(tab, "#open", in: harness.window)
    let popup = try await waitFor("popup window", timeout: 15) {
      NSApp.windows.first { $0.isVisible && $0.title == "127.0.0.1" }
    }
    let result = try await waitText(tab, { $0.hasPrefix("child says") }, "opener message")
    Clock.log("popup window \(popup.frame.size) opened with an opener: \(result)")
    try await settle(0.8)
    try await shoot(popup, "popup-window")
    try await eval(tab, "window.child.close()")
    try await waitUntil("popup closes with window.close()", timeout: 10) { !popup.isVisible }
    Clock.log("window.close() closed the popup window")
  }
}
