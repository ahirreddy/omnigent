internal import CoreGraphics
internal import Foundation

/// Where an element is, from `AgentBrowserScripts.locate`.
private struct ElementLocation: Decodable {
  let centerX: Double
  let centerY: Double
  let width: Double
  let height: Double
  let editable: Bool
  let tag: String

  enum CodingKeys: String, CodingKey {
    case centerX = "x"
    case centerY = "y"
    case width
    case height
    case editable
    case tag
  }

  var center: CGPoint { CGPoint(x: centerX, y: centerY) }
}

private struct ScriptFailure: Decodable {
  let error: String?
}

private struct FocusResult: Decodable {
  let focused: Bool
}

private struct ValueResult: Decodable {
  let value: String
  let hasValue: Bool
}

private struct ViewportPoint: Decodable {
  let horizontal: Double
  let vertical: Double

  enum CodingKeys: String, CodingKey {
    case horizontal = "x"
    case vertical = "y"
  }
}

/// `{href, readyState, title}` of a page.
struct AgentDocumentState: Decodable {
  let href: String
  let readyState: String
  let title: String
}

private struct SnapshotResult: Decodable {
  let snapshotID: String
  let url: String
  let title: String
  let tree: String

  enum CodingKeys: String, CodingKey {
    case snapshotID = "snapshot_id"
    case url
    case title
    case tree
  }
}

/// Running the actions.
extension AgentBrowserController {
  func run(_ action: AgentAction, on tab: any BrowserTab) async throws(BrowserError)
    -> AgentBrowserActionResult
  {
    switch action {
    case .navigate(let url):
      return try await navigate(url, tab)
    case .snapshot:
      let snapshot = try await evaluateJSON(AgentBrowserScripts.snapshot, SnapshotResult.self, tab)
      return .success([
        "snapshot_id": .string(snapshot.snapshotID), "url": .string(snapshot.url),
        "title": .string(snapshot.title), "tree": .string(snapshot.tree),
      ])
    case .evaluate(let expression):
      return .success(["value": AgentJSONValue(try await tab.evaluateJavaScript(expression))])
    case .waitForLoad(let timeout):
      let document = try await waitForLoad(tab, expecting: nil, timeout: timeout ?? actionTimeout)
      return .success(["url": .string(document.href), "title": .string(document.title)])
    case .screenshot:
      let png = try await tab.takeSnapshotPNG()
      return .success(dataURL: "data:image/png;base64," + png.base64EncodedString())
    case .click, .type, .press, .scroll:
      try await runInput(action, tab)
      return .success()
    }
  }

  private func runInput(_ action: AgentAction, _ tab: any BrowserTab) async throws(BrowserError) {
    switch action {
    case .click(let target):
      let location = try await locate(target, tab)
      try await tab.agentInput.click(at: location.center, clickCount: 1)
    case .type(let target, let text):
      try await type(text, into: target, tab)
    case .press(let key, let modifiers, let target):
      if let target {
        let focus = try await evaluateJSON(AgentBrowserScripts.focus(target), FocusResult.self, tab)
        guard focus.focused else { throw .agentActionFailed("The element did not take focus.") }
      }
      try await tab.agentInput.press(key, modifiers: modifiers)
    case .scroll(let deltaX, let deltaY, let target):
      let point: CGPoint
      if let target {
        point = try await locate(target, tab).center
      } else {
        let center = try await evaluateJSON(
          AgentBrowserScripts.viewportCenter, ViewportPoint.self, tab)
        point = CGPoint(x: center.horizontal, y: center.vertical)
      }
      try await tab.agentInput.scroll(at: point, deltaX: deltaX, deltaY: deltaY)
    default:
      throw .agentActionFailed("Not an input action.")
    }
    try await settleAfterInput(tab)
  }

  /// Renderer-direct input reaches the page asynchronously, on another channel than script
  /// evaluation; give it a moment, then wait out any navigation it started, so the next action
  /// sees its effect.
  private func settleAfterInput(_ tab: any BrowserTab) async throws(BrowserError) {
    do {
      try await Task.sleep(for: .milliseconds(tab.agentInput.isRendererDirect ? 150 : 30))
    } catch {
      throw .agentActionFailed("The action was cancelled.")
    }
    if tab.state.isLoading {
      _ = try await waitForLoad(tab, expecting: nil, timeout: actionTimeout)
    }
  }

  private func navigate(_ url: URL, _ tab: any BrowserTab) async throws(BrowserError)
    -> AgentBrowserActionResult
  {
    if case .deny(let reason) = urlPolicy.evaluate(url) {
      throw .navigationBlocked(url: url, reason: reason)
    }
    tab.load(url)
    let document = try await waitForLoad(tab, expecting: url, timeout: actionTimeout)
    return .success(["final_url": .string(document.href), "title": .string(document.title)])
  }

  private func type(_ text: String, into target: AgentElementTarget, _ tab: any BrowserTab)
    async throws(BrowserError)
  {
    let location = try await locate(target, tab)
    guard location.editable else {
      throw .agentActionFailed("The <\(location.tag)> element is not a text field.")
    }
    try await tab.agentInput.click(at: location.center, clickCount: 1)
    let focus = try await evaluateJSON(
      AgentBrowserScripts.focusAndSelect(target), FocusResult.self, tab)
    guard focus.focused else { throw .agentActionFailed("The element did not take focus.") }
    try await tab.agentInput.insertText(text)
    var value = try await evaluateJSON(AgentBrowserScripts.value(target), ValueResult.self, tab)
    for _ in 0..<20 where value.hasValue && !value.value.contains(text) {
      // Inserted text lands asynchronously in the renderer; poll briefly before failing.
      do {
        try await Task.sleep(for: .milliseconds(25))
      } catch {
        throw .agentActionFailed("The action was cancelled.")
      }
      value = try await evaluateJSON(AgentBrowserScripts.value(target), ValueResult.self, tab)
    }
    if value.hasValue, !value.value.contains(text) {
      throw .agentActionFailed(
        "The typed text did not reach the element; its value is \"\(value.value.prefix(80))\".")
    }
  }

  private func locate(_ target: AgentElementTarget, _ tab: any BrowserTab)
    async throws(BrowserError) -> ElementLocation
  {
    let location = try await evaluateJSON(
      AgentBrowserScripts.locate(target), ElementLocation.self, tab)
    guard location.width > 0, location.height > 0 else {
      throw .agentActionFailed("The <\(location.tag)> element has no visible box to act on.")
    }
    return location
  }

  /// Runs a script that returns a JSON string, failing with its `{"error"}` when it has one.
  func evaluateJSON<T: Decodable>(_ script: String, _ type: T.Type, _ tab: any BrowserTab)
    async throws(BrowserError) -> T
  {
    let value = try await tab.evaluateJavaScript(script)
    guard case .string(let json) = value else {
      throw .agentActionFailed("The page script returned \(value) instead of JSON.")
    }
    let data = Data(json.utf8)
    do {
      if let message = try JSONDecoder().decode(ScriptFailure.self, from: data).error {
        throw BrowserError.agentActionFailed(message)
      }
      return try JSONDecoder().decode(type, from: data)
    } catch let error as BrowserError {
      throw error
    } catch {
      throw .agentActionFailed("The page script returned malformed JSON: \(error)")
    }
  }

  /// Waits until the document is complete and, after a navigation, until it is the new one.
  func waitForLoad(_ tab: any BrowserTab, expecting url: URL?, timeout: Duration)
    async throws(BrowserError) -> AgentDocumentState
  {
    let start = ContinuousClock.now
    var sawLoading = false
    repeat {
      let state = tab.state
      if state.isClosed { throw .tabClosed }
      if let error = state.lastError, !error.isCancellation { throw error }
      sawLoading = sawLoading || state.isLoading
      let elapsed = ContinuousClock.now - start
      if !state.isLoading, let document = try await documentState(tab),
        document.readyState == "complete",
        url == nil || sawLoading || document.href == url?.absoluteString || elapsed > .seconds(2)
      {
        return document
      }
      do {
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        throw .agentActionFailed("The action was cancelled.")
      }
    } while ContinuousClock.now - start <= timeout
    throw .agentActionFailed(
      "The page did not finish loading within \(timeout.components.seconds) seconds.")
  }

  /// The document state, or nil while the engine is still creating the page.
  private func documentState(_ tab: any BrowserTab) async throws(BrowserError)
    -> AgentDocumentState?
  {
    do {
      return try await evaluateJSON(
        AgentBrowserScripts.documentState, AgentDocumentState.self, tab)
    } catch .tabNotReady {
      return nil
    }
  }
}
