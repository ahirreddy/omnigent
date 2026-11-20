import Foundation

/// The web's title for a question card: a workflow question names its task; otherwise the
/// asking harness. An MCP server's form keeps the plain title, since the server asks, not the
/// agent.
enum DecisionQuestionTitle {
  /// Harness prefixes of a question's policy or phase, and the web's title for each.
  private static let harnessTitles: [(prefix: String, title: String)] = [
    ("agy_", "Antigravity needs your input"), ("codex_", "Codex needs input"),
    ("cursor_", "Cursor has questions"), ("pi_", "Pi needs your input"),
    ("devin_", "Devin needs your input"), ("opencode_", "OpenCode has questions"),
    ("claude_", "Claude has questions"),
  ]

  /// The web's title for any card: its kind's, or the question's.
  static func cardTitle(for card: DecisionCard) -> String {
    if card.permissions.plan != nil { return "Plan review" }
    if card.permissions.command != nil { return "Command approval" }
    switch card.kind {
    case .approval: return DecisionSummary.isGeneric(card.title) ? "Approval required" : card.title
    case .choice: return "Choose an option"
    case .form: return DecisionSummary.isGeneric(card.title) ? title(for: card) : card.title
    case .externalPage, .unsupported: return card.title
    }
  }

  /// Whether `card`'s form holds an agent's or a workflow's questions rather than an MCP
  /// server's fields.
  static func asksQuestions(_ card: DecisionCard) -> Bool {
    let phase = card.phase ?? ""
    let names = [card.policyName ?? "", phase]
    if names.contains(where: { $0.hasSuffix("_mcp_elicitation") }) { return false }
    if phase == "workflow_request_input" { return true }
    return harnessTitles.contains { entry in names.contains { $0.hasPrefix(entry.prefix) } }
  }

  /// The title for `card`, a question or form.
  static func title(for card: DecisionCard) -> String {
    let phase = card.phase ?? ""
    if phase == "workflow_request_input", let message = card.message { return message }
    if phase.hasSuffix("_mcp_elicitation") { return "Questions" }
    let names = [card.policyName ?? "", phase]
    return harnessTitles.first { entry in names.contains { $0.hasPrefix(entry.prefix) } }?
      .title ?? "Questions"
  }
}
