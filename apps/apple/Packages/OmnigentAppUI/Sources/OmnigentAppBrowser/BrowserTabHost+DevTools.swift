public import Foundation
import OSLog
import OmnigentAppUI
public import OmnigentBrowser
import OmnigentUIComponents

/// A page an agent may drive over Chrome DevTools, as the runner's proxy lists it.
nonisolated public struct BrowserDevToolsTab: Encodable, Equatable, Sendable {
  /// The app tab's id.
  public let tabID: String
  /// The page's DevTools target id.
  public let targetID: String
  /// The committed URL.
  public let url: String
  /// The title.
  public let title: String
  /// `user` while the user holds the page, else `agent`.
  public let owner: String

  enum CodingKeys: String, CodingKey {
    case tabID = "tab_id"
    case targetID = "target_id"
    case url, title, owner
  }
}

/// The session's browser pages for an agent's DevTools proxy: listing them with their target
/// ids, opening background tabs in the session's tab set, closing them, and the agent's state
/// for each page's badge and strip. Pages live in `models` whatever window or session shows,
/// and a held page keeps rendering while hidden.
extension BrowserTabHost {
  /// How long a new page may take to report its DevTools target.
  private static let targetWait = Duration.seconds(5)
  private static let targetPoll = Duration.milliseconds(100)

  static func badge(_ control: BrowserAgentControl) -> TabAgentControl {
    switch control {
    case .active: .active
    case .idle: .idle
    case .user: .user
    }
  }

  /// Lists `sessionID`'s browser tabs in every window, building pages it has not shown yet.
  /// A page that has not reported its target yet joins a later listing.
  /// - Parameter sessionID: The session.
  /// - Returns: The tabs.
  public func devToolsTabs(sessionID: String) async -> [BrowserDevToolsTab] {
    var listed: [BrowserDevToolsTab] = []
    for tab in sessionBrowserTabs(sessionID) {
      guard case .browser(let id) = tab.content, let model = livePage(id, state: tab.browserState),
        let target = await devToolsTarget(of: id, model: model, waiting: false)
      else { continue }
      listed.append(record(tabID: tab.id, targetID: target, model: model))
    }
    return listed
  }

  /// Opens a background tab in `sessionID`'s tab set, in the user's default profile, for the
  /// agent. It never takes the window's selection, and it stays on Chromium (the engine with
  /// DevTools) whatever the user's engine preference.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - url: The first page; `nil` opens a blank page.
  ///   - stopTurn: Stops the session's turn, for the agent strip's Stop.
  /// - Returns: The new tab.
  /// - Throws: When no window can hold the tab or the page does not start.
  public func openDevToolsTab(
    sessionID: String, url: URL?, stopTurn: @escaping @MainActor () -> Void
  ) async throws(BrowserError) -> BrowserDevToolsTab {
    guard
      let tabs = windows.values.first(where: { $0.groups[sessionID] != nil })
        ?? windows.values.first
    else { throw .notAllowed("No window is open to hold the agent's tab.") }
    let page = makePage(url: url, engine: .chromium)
    guard let model = models[page.id] else { throw .tabClosed }
    model.activate()
    let appTab = tabs.group(sessionID).open(
      .browser(browserID: page.id), select: false, browserState: page.state)
    guard let target = await devToolsTarget(of: page.id, model: model, waiting: true) else {
      // A page the agent cannot reach is no use to it; it never shows as a stray tab.
      tabs.close(appTab.id)
      throw .devToolsFailed(
        method: "Target.getTargetInfo",
        message: "The new tab did not start in time, or the browser engine has no DevTools.")
    }
    holdForAgent(model, control: .active, stopTurn: stopTurn)
    keepHeldSessionsOpen()
    return record(tabID: appTab.id, targetID: target, model: model)
  }

  /// Closes `sessionID`'s tab whose page is `targetID`.
  /// - Throws: `tabClosed` when the session has no such page.
  public func closeDevToolsTab(sessionID: String, targetID: String) throws(BrowserError) {
    let id = try page(target: targetID, sessionID: sessionID)
    for tabs in windows.values {
      for group in tabs.groups.values {
        if let tab = group.tabs.first(where: { $0.content == .browser(browserID: id) }) {
          tabs.close(tab.id)
          keepHeldSessionsOpen()
          return
        }
      }
    }
    throw .tabClosed
  }

  /// Records what the agent does on a page: `active`, `idle`, or `released` when its
  /// connection ended. The user's own control is never overridden by the agent's reports.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - targetID: The page's DevTools target.
  ///   - state: `active`, `idle` or `released`.
  ///   - stopTurn: Stops the session's turn, for the agent strip's Stop.
  /// - Throws: `tabClosed` for an unknown page, `notAllowed` for an unknown state.
  public func setDevToolsAgentState(
    sessionID: String, targetID: String, state: String,
    stopTurn: @escaping @MainActor () -> Void
  ) throws(BrowserError) {
    let id = try page(target: targetID, sessionID: sessionID)
    guard let model = models[id] else { throw .tabClosed }
    switch state {
    case "active", "idle":
      guard model.agentControl != .user else { return }
      holdForAgent(model, control: state == "active" ? .active : .idle, stopTurn: stopTurn)
    case "released":
      model.setAgentControl(nil)
    default:
      throw .notAllowed("Unknown agent state \(state).")
    }
    keepHeldSessionsOpen()
  }

  /// Keeps each window's sessions open while an agent holds one of their browser tabs.
  func keepHeldSessionsOpen() {
    for groups in windows.values {
      let held = Set(
        groups.groups.compactMap { sessionID, tabs -> String? in
          let holds = tabs.tabs.contains { tab in
            guard case .browser(let id) = tab.content else { return false }
            return models[id]?.agentControl != nil
          }
          return holds ? sessionID : nil
        })
      if groups.agentHeldSessions != held { groups.agentHeldSessions = held }
    }
  }

  // MARK: Internals

  private func sessionBrowserTabs(_ sessionID: String) -> [AppTab] {
    windows.values.compactMap { $0.groups[sessionID] }.flatMap(\.tabs).filter {
      if case .browser = $0.content { true } else { false }
    }
  }

  /// The page, built from its saved state when the session never showed it.
  private func livePage(_ id: UUID, state: Data?) -> BrowserTabModel? {
    if let model = models[id] {
      if !model.isActivated { model.activate() }
      return model
    }
    do {
      let model = try restore(id, from: state)
      model.activate()
      return model
    } catch {
      logger.error(
        "An agent's browser tab could not be restored: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  private func devToolsTarget(of id: UUID, model: BrowserTabModel, waiting: Bool) async -> String? {
    if let known = devToolsTargets[id] { return known }
    let deadline = ContinuousClock.now + (waiting ? Self.targetWait : .zero)
    while true {
      if let tab = model.tab {
        do {
          guard let target = try await tab.agentInput.devToolsTargetID() else { return nil }
          devToolsTargets[id] = target
          return target
        } catch {
          // A page that is still starting has no DevTools session yet.
          guard ContinuousClock.now < deadline else {
            logger.info(
              "A browser page has no DevTools target yet: \(String(describing: error), privacy: .public)"
            )
            return nil
          }
        }
      }
      guard ContinuousClock.now < deadline else { return nil }
      do {
        try await Task.sleep(for: Self.targetPoll)
      } catch {
        return nil
      }
    }
  }

  private func page(target: String, sessionID: String) throws(BrowserError) -> UUID {
    let inSession = Set(
      sessionBrowserTabs(sessionID).compactMap { tab -> UUID? in
        if case .browser(let id) = tab.content { id } else { nil }
      })
    guard
      let id = devToolsTargets.first(where: { $0.value == target && inSession.contains($0.key) })?
        .key
    else { throw .tabClosed }
    return id
  }

  private func holdForAgent(
    _ model: BrowserTabModel, control: BrowserAgentControl,
    stopTurn: @escaping @MainActor () -> Void
  ) {
    model.setAgentControl(control)
    model.agentControlAction = { action in
      if action == .stop { stopTurn() }
    }
  }

  private func record(tabID: String, targetID: String, model: BrowserTabModel)
    -> BrowserDevToolsTab
  {
    BrowserDevToolsTab(
      tabID: tabID, targetID: targetID, url: model.url?.absoluteString ?? "",
      title: model.displayTitle, owner: model.agentControl == .user ? "user" : "agent")
  }
}
