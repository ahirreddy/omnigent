internal import AppKit
internal import Foundation
internal import OmnigentBrowser
internal import OmnigentWebLayer

/// `browser.action_request` end to end through `AgentBrowserController`: navigate, snapshot,
/// type, click, a dialog the agent triggers, a screenshot with an open `<select>`, and the URL
/// policy (direct navigation and a redirect).
extension Proofs {
  private func act(
    _ controller: AgentBrowserController, _ action: String, _ args: [String: AgentJSONValue] = [:]
  ) async throws -> AgentBrowserActionResult {
    let result = await controller.perform(
      AgentBrowserActionRequest(
        actionID: "baction_proof_\(UUID().uuidString.prefix(8))", action: action, args: args,
        conversationID: "conv_owl2_proof"))
    let json = String(bytes: try result.jsonData(), encoding: .utf8) ?? "?"
    Clock.log("agent \(action) -> \(json.count > 400 ? String(json.prefix(400)) + "…" : json)")
    return result
  }

  private func require(_ result: AgentBrowserActionResult, _ what: String) throws {
    guard result.ok else { throw ProofFailure("\(what) failed: \(result.error ?? "no error")") }
  }

  private func ref(_ role: String, _ name: String, in tree: String) throws -> Double {
    let line = tree.split(separator: "\n").first { $0.contains("- \(role) \"\(name)\"") }
    guard let line, let range = line.range(of: #"\[ref=(\d+)\]"#, options: .regularExpression),
      let number = Double(line[range].dropFirst(5).dropLast())
    else {
      throw ProofFailure("No \(role) \"\(name)\" in the snapshot:\n\(tree)")
    }
    return number
  }

  func agentActions() async throws {
    if engine == .chromium { try await model.session.waitUntilReady() }
    let controller = AgentBrowserController(
      provider: provider, engine: engine, urlPolicy: BrowserURLRules(allowLoopback: true))
    defer { controller.closeAll() }
    let page = try await pageURL("agent").absoluteString
    try require(try await act(controller, "navigate", ["url": .string(page)]), "navigate")
    let snapshot = try await act(controller, "snapshot")
    try require(snapshot, "snapshot")
    guard case .string(let tree)? = snapshot.data["tree"],
      let snapshotID = snapshot.data["snapshot_id"]
    else {
      throw ProofFailure("The snapshot has no tree.")
    }
    let query = try ref("textbox", "search terms", in: tree)
    let search = try ref("button", "Search", in: tree)
    try require(
      try await act(
        controller, "type",
        ["ref": .number(query), "snapshot_id": snapshotID, "text": "owl agent query"]), "type")
    try require(
      try await act(controller, "click", ["ref": .number(search), "snapshot_id": snapshotID]),
      "click")
    let submitted = try await act(
      controller, "evaluate", ["expression": "document.querySelector('#result').textContent"])
    guard submitted.data["value"] == .string("submitted owl agent query") else {
      throw ProofFailure("The agent's form submission did not land: \(submitted.data)")
    }
    let warned = try await act(controller, "click", ["selector": "#warn"])
    guard case .array(let dialogs)? = warned.data["dialogs"], !dialogs.isEmpty else {
      throw ProofFailure("The agent's alert was not auto-handled and reported.")
    }
    try await agentScreenshot(controller)
    try await agentPolicy(controller)
    try agentStaysOffApp(controller)
  }

  private func agentScreenshot(_ controller: AgentBrowserController) async throws {
    try require(try await act(controller, "click", ["selector": "#fruit"]), "open select")
    try await settle(0.5)
    let shot = try await act(controller, "screenshot")
    try require(shot, "screenshot")
    guard let dataURL = shot.dataURL, let comma = dataURL.firstIndex(of: ","),
      let png = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
    else {
      throw ProofFailure("The screenshot is not a PNG data URL.")
    }
    let url = outputDirectory.appending(path: "owl2-agent-screenshot-\(engineSuffix).png")
    try png.write(to: url)
    Clock.log("agent screenshot \(url.path): \(png.count) bytes, prefix \(dataURL.prefix(22))")
    try require(try await act(controller, "press", ["key": "Escape"]), "press Escape")
  }

  private func agentPolicy(_ controller: AgentBrowserController) async throws {
    let metadata = try await act(
      controller, "navigate", ["url": "http://169.254.169.254/latest/meta-data/"])
    guard !metadata.ok, metadata.error?.contains("private address") == true else {
      throw ProofFailure("The URL policy let the agent reach cloud metadata.")
    }
    let base = try await proofServer().base
    let redirect = try await act(
      controller, "navigate", ["url": .string("\(base)/redirect?to=http://10.11.12.13/secret")])
    let landed = controller.activeTab(conversationID: "conv_owl2_proof")?.state.url
    Clock.log(
      "redirect to a private address: ok=\(redirect.ok) landed on \(landed?.absoluteString ?? "-")")
    guard !redirect.ok, landed?.host != "10.11.12.13" else {
      throw ProofFailure("A redirect took the agent to a private address.")
    }
  }

  /// Agent pages are never in an app window: Chromium pages render in the host with no window,
  /// WebKit pages in an off-screen, non-activating panel that ignores the mouse.
  private func agentStaysOffApp(_ controller: AgentBrowserController) throws {
    guard let tab = controller.activeTab(conversationID: "conv_owl2_proof") else {
      throw ProofFailure("No agent page.")
    }
    guard let window = unsafe tab.platformView.window else {
      Clock.log("agent page: in no window; \(NSApp.windows.count) app windows untouched")
      guard engine == .chromium else { throw ProofFailure("The WebKit agent page has no host.") }
      return
    }
    let onScreen = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    Clock.log(
      "agent page window: \(Swift.type(of: window)) at \(window.frame.origin), on screen \(onScreen), key \(window.isKeyWindow), ignores mouse \(window.ignoresMouseEvents)"
    )
    guard window is NSPanel, !onScreen, !window.isKeyWindow, window.ignoresMouseEvents else {
      throw ProofFailure("The agent page is reachable from the app's UI.")
    }
  }
}
