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
