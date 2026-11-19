#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// How each harness's question reads: the web's titles, and long choice lists as a menu.
  @Suite("Decision card: question kinds", .serialized)
  @MainActor
  struct DecisionQuestionKindsTests {
    private let log = DecisionResponseLog()

    private func question(
      policyName: String?, phase: String? = "pre_tool_use", message: String? = nil
    ) -> DecisionCard {
      DecisionCard(
        id: "question", carryingSessionId: "session", title: "Response requested",
        detail: message ?? "Which layout?",
        kind: .form(fields: [FormField(key: "layout", title: "Which layout?", kind: .text)]),
        phase: phase, policyName: policyName, message: message)
    }

    /// Who asks, and the title the web gives the question.
    private struct TitleCase {
      let policy: String?
      let phase: String?
      let title: String
    }

    @Test("A question is titled by the harness that asks it, as on the web")
    func harnessTitles() {
      let cases = [
        TitleCase(
          policy: "claude_native_permission", phase: "pre_tool_use", title: "Claude has questions"),
        TitleCase(
          policy: "claude_sdk_permission", phase: "pre_tool_use", title: "Claude has questions"),
        TitleCase(
          policy: "codex_native_request_user_input", phase: "codex_request_user_input",
          title: "Codex needs input"),
        TitleCase(
          policy: "agy_native_ask_question", phase: "agy_ask_question",
          title: "Antigravity needs your input"),
        TitleCase(
          policy: "pi_native_extension_ui", phase: "pi_extension_ui", title: "Pi needs your input"),
        TitleCase(
          policy: "devin_native_ask_question", phase: "pre_tool_use",
          title: "Devin needs your input"),
        TitleCase(
          policy: "cursor_native_permission", phase: "pre_tool_use", title: "Cursor has questions"),
        TitleCase(
          policy: "opencode_native_question", phase: "pre_tool_use", title: "OpenCode has questions"
        ),
        // An MCP server's form is the server's, not the agent's.
        TitleCase(
          policy: "claude_native_mcp_elicitation", phase: "claude_mcp_elicitation",
          title: "Questions"),
        TitleCase(
          policy: "codex_native_mcp_elicitation", phase: "codex_mcp_elicitation", title: "Questions"
        ),
        TitleCase(policy: nil, phase: nil, title: "Questions"),
      ]
      for entry in cases {
        let card = question(policyName: entry.policy, phase: entry.phase)
        #expect(DecisionQuestionTitle.title(for: card) == entry.title, "\(entry.policy ?? "none")")
      }
    }

    @Test("A workflow question is titled by the task waiting on it")
    func workflowTitle() throws {
      let card = question(
        policyName: nil, phase: "workflow_request_input",
        message: "Waiting for you on Pick the cache")
      #expect(DecisionQuestionTitle.title(for: card) == "Waiting for you on Pick the cache")
      let screen = OffscreenWindow(
        DecisionCardScreen(card: card, model: DecisionCardModel(), log: log))
      defer { screen.close() }
      screen.settle()
      // The title is the message, so the message is not repeated under it.
      let shown = try screen.shownText().filter { $0.contains("Waiting for you on Pick the cache") }
      #expect(shown.count == 1)
    }

    @Test("The harness title heads the card")
    func titleOnCard() throws {
      let screen = OffscreenWindow(
        DecisionCardScreen(
          card: question(policyName: "codex_native_request_user_input"),
          model: DecisionCardModel(), log: log))
      defer { screen.close() }
      screen.settle()
      #expect(try screen.shows("Codex needs input"))
    }

    @Test("A long list of bare options picks from a menu; short or described lists stay rows")
    func longChoicesUseAMenu() {
      func field(_ count: Int, kind: FieldKind = .singleChoice, detail: String = "") -> FormField {
        FormField(
          key: "model", title: "Model", kind: kind,
          options: (1...count).map { FormOption(value: "model-\($0)", detail: detail) })
      }
      let threshold = DecisionFormFields.menuThreshold
      #expect(DecisionFormFields.choosesFromMenu(field(threshold + 1)))
      #expect(!DecisionFormFields.choosesFromMenu(field(threshold)))
      #expect(!DecisionFormFields.choosesFromMenu(field(threshold + 1, detail: "Fast")))
      #expect(!DecisionFormFields.choosesFromMenu(field(threshold + 1, kind: .multipleChoice)))
    }
  }
#endif
