import Foundation

extension PreviewData {
  /// Automations: an active pair and a paused one.
  static var automations: AutomationsViewState {
    var paused = AutomationRow(
      id: "t3", name: "News digest", scheduleText: "Every day at 7:30 AM", isPaused: true)
    paused.lastRunSessionID = sessionID
    let rows = [
      AutomationRow(
        id: "t1", name: "Follow-up monitor", scheduleText: "Weekdays at 9:00 AM",
        nextRunText: "in 3 hours"),
      AutomationRow(
        id: "t2", name: "PR sweep", scheduleText: "Every 2 hours at :15",
        nextRunText: "in 48 mins"),
      paused,
    ]
    return AutomationsViewState(rows: rows, hasAny: true)
  }

  /// A month of spend.
  static var usage: UsageViewState {
    let days = (0..<14).map { offset in
      UsageAmount(
        label: "2026-10-\(18 + offset)",
        costUSD: Double((offset * 37) % 11) * 0.42 + 0.3)
    }
    return UsageViewState(
      totalText: "$31.84", daily: days,
      byHarness: [
        UsageAmount(label: "claude-code", costUSD: 22.1),
        UsageAmount(label: "codex", costUSD: 9.74),
      ],
      byModel: [
        UsageAmount(label: "claude-opus-4", costUSD: 18.2),
        UsageAmount(label: "gpt-5-codex", costUSD: 9.74),
        UsageAmount(label: "claude-sonnet-4", costUSD: 3.9),
      ],
      sessions: sessions.prefix(4).enumerated().map { index, session in
        UsageSessionRow(
          id: session.id, title: session.title, model: "claude-opus-4", harness: "claude-code",
          updatedAt: now.addingTimeInterval(TimeInterval(-3_600 * (index + 1))),
          costUSD: Double(4 - index) * 2.5, costText: cost(Double(4 - index) * 2.5))
      })
  }

  /// Formats a sample cost.
  static func cost(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
}

extension PreviewData {
  /// A Canvas board of `sessions` on a grid, with one project board.
  static func canvas(_ sessions: [SessionSummary]) -> CanvasViewState {
    let cards = sessions.prefix(12).enumerated().map { index, session in
      CanvasCard(
        id: session.id, title: session.title, state: CanvasCard.State(session.attention),
        workspace: session.workspace.isEmpty ? "No working directory" : session.workspace,
        left: (index % 4) * 320, top: (index / 4) * 160)
    }
    return CanvasViewState(
      boards: [
        CanvasBoard(id: "main", name: "Main"),
        CanvasBoard(id: "p1", name: "Docs", icon: "\u{1F4DA}"),
      ],
      activeBoard: "main", cards: Array(cards))
  }
}

extension CanvasCard.State {
  /// The card state for a sidebar attention state.
  public init(_ attention: SessionAttentionState) {
    switch attention {
    case .needsYou: self = .needsYou
    case .failed: self = .failed
    case .working: self = .running
    case .unread: self = .unread
    case .idle: self = .idle
    }
  }
}
