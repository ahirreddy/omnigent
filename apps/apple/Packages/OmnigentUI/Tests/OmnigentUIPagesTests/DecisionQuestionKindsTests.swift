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

    /// `Claude--AskUserQuestion--FourQuestions`: its fields as the core builds them.
    private let fourQuestions = [
      FormField(
        key: "Where should the settings live?", title: "Where should the settings live?",
        detail: "Storage", kind: .singleChoice,
        options: [FormOption(value: "A file in the repo"), FormOption(value: "The database")],
        allowsCustom: true),
      FormField(
        key: "Which platforms need the change?", title: "Which platforms need the change?",
        detail: "Platforms", kind: .multipleChoice,
        options: [
          FormOption(value: "Mac"), FormOption(value: "iPhone"), FormOption(value: "iPad"),
        ],
        allowsCustom: true),
      FormField(
        key: "How should a failed save be reported?",
        title: "How should a failed save be reported?", detail: "Errors", kind: .singleChoice,
        options: [FormOption(value: "A banner"), FormOption(value: "A toast")], allowsCustom: true),
    ]

    @Test("A question card's Submit names the first unanswered question, wherever it is")
    func questionSubmitReason() {
      var draft = FormDraft()
      let reason = {
        draft.submitBlockedReason(for: fourQuestions, asQuestions: true, validatorProblem: nil)
      }
      #expect(reason() == "Answer question 1 (Storage) to submit")
      draft.selected[fourQuestions[0].key] = ["The database"]
      // A multi-select starts empty, so skipping it keeps Submit off.
      draft.selected[fourQuestions[2].key] = ["A toast"]
      #expect(reason() == "Answer question 2 (Platforms) to submit")
      draft.custom[fourQuestions[1].key] = "Vision"
      #expect(reason() == nil)
      // A question without a header (Pi, Codex free text) is named by its number alone.
      let bare = FormField(key: "0", title: "Pick a model", kind: .text)
      #expect(
        FormDraft().submitBlockedReason(for: [bare], asQuestions: true, validatorProblem: nil)
          == "Answer question 1 to submit")
    }

    @Test("An MCP form's Submit gives the first field's problem; a validator's stands as it is")
    func formSubmitReason() {
      let fields = [
        FormField(key: "attempts", title: "Attempts", kind: .integer, required: false),
        FormField(key: "version", title: "Version", kind: .text),
      ]
      var draft = FormDraft()
      #expect(
        draft.submitBlockedReason(for: fields, asQuestions: false, validatorProblem: nil)
          == "Enter Version.")
      draft.text["attempts"] = "two"
      #expect(
        draft.submitBlockedReason(for: fields, asQuestions: false, validatorProblem: nil)
          == "Attempts must be a whole number.")
      draft.text = ["attempts": "2", "version": "2.4"]
      #expect(
        draft.submitBlockedReason(
          for: fields, asQuestions: false,
          validatorProblem: "Version must be at least 3 characters.")
          == "Version must be at least 3 characters.")
      #expect(
        draft.submitBlockedReason(for: fields, asQuestions: false, validatorProblem: nil) == nil)
    }

    @Test("Agent and workflow questions read as questions; MCP forms don't")
    func questionsOrFields() {
      let questions: [(String?, String?)] = [
        ("claude_native_permission", "pre_tool_use"), ("claude_sdk_permission", "pre_tool_use"),
        ("codex_native_request_user_input", "codex_request_user_input"),
        ("agy_native_ask_question", "agy_ask_question"),
        ("pi_native_extension_ui", "pi_extension_ui"),
        ("devin_native_ask_question", "pre_tool_use"), ("cursor_native_permission", "pre_tool_use"),
        ("opencode_native_question", "pre_tool_use"), (nil, "workflow_request_input"),
      ]
      for (policy, phase) in questions {
        #expect(DecisionQuestionTitle.asksQuestions(question(policyName: policy, phase: phase)))
      }
      let forms: [(String?, String?)] = [
        ("claude_native_mcp_elicitation", "claude_mcp_elicitation"),
        ("claude_sdk_mcp_elicitation", "claude_sdk_mcp_elicitation"),
        ("codex_native_mcp_elicitation", "codex_mcp_elicitation"), (nil, nil),
      ]
      for (policy, phase) in forms {
        #expect(!DecisionQuestionTitle.asksQuestions(question(policyName: policy, phase: phase)))
      }
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
