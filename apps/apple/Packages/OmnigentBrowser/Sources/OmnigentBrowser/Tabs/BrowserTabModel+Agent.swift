/// What an agent driving a page over Chrome DevTools is doing to it.
nonisolated public enum BrowserAgentControl: Hashable, Sendable {
  /// The agent acted on the page in the last few seconds.
  case active
  /// The agent holds the page but has not acted recently.
  case idle
  /// The user took over; the agent's clicks, typing and navigation are refused until the user
  /// hands the page back.
  case user
}

/// The agent strip's buttons.
nonisolated public enum BrowserAgentControlAction: Hashable, Sendable {
  /// The user takes the page; the agent must wait.
  case takeOver
  /// The user gives the page back to the agent.
  case handBack
  /// The user takes the page and stops the agent's turn. The tab stays open.
  case stop
}

extension BrowserTabModel {
  /// Records what the agent is doing, and keeps the page rendering, running timers and taking
  /// input while an agent holds it, wherever its tab is (another tab, another session, a
  /// background or minimized window).
  /// - Parameter control: The agent's state; `nil` when no agent holds the page.
  public func setAgentControl(_ control: BrowserAgentControl?) {
    agentControl = control
    tab?.agentInput.holdForAgent(control != nil)
  }

  /// Runs one of the agent strip's buttons.
  /// - Parameter action: The button.
  public func performAgentControl(_ action: BrowserAgentControlAction) {
    switch action {
    case .takeOver, .stop: setAgentControl(.user)
    case .handBack: setAgentControl(.idle)
    }
    agentControlAction?(action)
  }
}
