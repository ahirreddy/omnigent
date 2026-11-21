import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The session's browser choice (the `omnigent.browser_target` label) for the Mac toolbar's chip
/// and the iOS title menu.
@MainActor
enum BrowserTargetAdapter {
  /// The chip's state.
  /// - Parameters:
  ///   - panel: The session's panel store, which reads the choice.
  ///   - isShared: The session is someone else's or shared with others: This Mac is off.
  /// - Returns: `nil`, which hides the chip, until the server offers the agent browser and the
  ///   choice is read.
  static func state(_ panel: SessionPanelStore?, isShared: Bool) -> BrowserTargetState? {
    guard let panel, panel.offersAgentBrowser, let target = panel.browserTarget else {
      return nil
    }
    return BrowserTargetState(
      choice: choice(target), localUnavailableReason: isShared ? BrowserTargetState.ownerOnly : nil)
  }

  /// What picking a browser does: saves it, and reports a refusal through `report`.
  /// - Returns: `nil` where the server offers no agent browser.
  static func chooser(
    _ panel: SessionPanelStore?, report: @escaping @MainActor (String) -> Void
  ) -> (@MainActor (BrowserTargetChoice) -> Void)? {
    guard let panel, panel.offersAgentBrowser else { return nil }
    return { choice in
      Task {
        if let error = await panel.setBrowserTarget(target(choice)) { report(failure(error)) }
      }
    }
  }

  /// What a refused change says: the server's 403 is the owner-only rule.
  static func failure(_ error: CoreError) -> String {
    if case .Session(.forbidden, _, _, _, _) = error { return BrowserTargetState.ownerOnly }
    return error.message
  }

  static func choice(_ target: BrowserTarget) -> BrowserTargetChoice {
    switch target {
    case .auto: .auto
    case .local: .local
    case .remote: .remote
    }
  }

  static func target(_ choice: BrowserTargetChoice) -> BrowserTarget {
    switch choice {
    case .auto: .auto
    case .local: .local
    case .remote: .remote
    }
  }
}
