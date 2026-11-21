import Foundation
public import OmnigentCoreFFI

extension SessionPanelStore {
  /// Whether the server lets session agents drive a browser through Chrome DevTools.
  public var offersAgentBrowser: Bool { features?.agentBrowserDevtools == true }

  /// Reads which browser the session's agent drives, where the server offers the agent browser.
  /// A failed read keeps the last choice and records ``browserTargetError``.
  public func loadBrowserTarget() async {
    await loadFeatures()
    guard offersAgentBrowser else { return }
    do {
      let target = try await core.browserTarget(sessionId: sessionID)
      if browserTarget != target { browserTarget = target }
      browserTargetError = nil
    } catch {
      browserTargetError = coreError(error)
    }
  }

  /// Points the session's agent at `target`. The choice shows at once and is put back when
  /// the server refuses it.
  /// - Parameter target: The browser.
  /// - Returns: Why the change failed (`forbidden` for `local` from anyone but the owner of an
  ///   unshared session); `nil` once it is saved.
  public func setBrowserTarget(_ target: BrowserTarget) async -> CoreError? {
    let previous = browserTarget
    browserTarget = target
    do {
      try await core.setBrowserTarget(sessionId: sessionID, target: target)
      return nil
    } catch {
      if browserTarget == target { browserTarget = previous }
      return coreError(error)
    }
  }
}
