import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// The question kinds the core now answers natively, as it builds their cards from the shared
/// fixtures in `client-core/fixtures/decisions`.
@MainActor
extension LookFixtures {
  /// `Codex--ToolRequestUserInput--DefaultModeRepeatedOption`: the repeated label offered once.
  static let codexQuestion = DecisionCard(
    id: "elic_codex_question", carryingSessionId: "sess_look", title: "Response requested",
    detail: "Codex needs input",
    kind: .form(fields: [
      FormField(
        key: "test_scope", title: "Which tests should run before the change lands?",
        detail: "Tests", kind: .singleChoice,
        options: [
          FormOption(value: "Unit tests", detail: "The core crate only."),
          FormOption(value: "Unit and UI tests", detail: "Adds the Mac flows."),
        ], allowsCustom: true)
    ]), phase: "codex_request_user_input", policyName: "codex_native_request_user_input",
    message: "Codex needs input", agentKeepsWorking: true)

  static var codexQuestionDraft: FormDraft {
    var draft = FormDraft()
    draft.selected = ["test_scope": ["Unit and UI tests"]]
    return draft
  }

  /// `Omni--McpElicitation--OptionalFields`: a Python MCP server's optional and `Literal` fields.
  static let optionalFields = DecisionCard(
    id: "elic_optional_fields", carryingSessionId: "sess_look", title: "Response requested",
    detail: "Which release should the changelog describe?",
    kind: .form(fields: [
      FormField(
        key: "attempts", title: "Attempts", kind: .integer, required: false, minimum: 1),
      FormField(
        key: "channel", title: "Channel", kind: .singleChoice, required: false,
        options: [FormOption(value: "beta")], defaultValue: .text(value: "beta")),
      FormField(
        key: "hotfix", title: "Hotfix", kind: .boolean, required: false,
        defaultValue: .bool(value: false)),
      FormField(key: "notes", title: "Notes", kind: .text, required: false),
      FormField(key: "version", title: "Version", kind: .text),
    ]), message: "Which release should the changelog describe?")

  static var optionalFieldsDraft: FormDraft {
    var draft = FormDraft()
    draft.text = ["version": "2.4.0", "notes": "Fixes the sign-in loop."]
    return draft
  }

  /// A Pi `select` dialog longer than the radio list shows: a pop-up menu.
  static let longSelect = DecisionCard(
    id: "elic_pi_select", carryingSessionId: "sess_look", title: "Response requested",
    detail: "Pick a model",
    kind: .form(fields: [
      FormField(
        key: "0", title: "Pick a model", kind: .singleChoice,
        options: [
          "atlas-small", "atlas-medium", "atlas-large", "boreal-mini", "boreal-pro", "cedar-1",
          "cedar-2", "delta-lite", "delta-max", "ember-fast", "ember-deep", "fjord-8b",
          "fjord-70b", "gale-turbo",
        ].map { FormOption(value: $0) })
    ]), phase: "pi_extension_ui", policyName: "pi_native_extension_ui")

  static var longSelectDraft: FormDraft {
    var draft = FormDraft()
    draft.selected = ["0": ["boreal-pro"]]
    return draft
  }

  /// `Claude--AskUserQuestion--NoUsableQuestion`: the tool's approval, as on the web.
  static let questionFallback = DecisionCard(
    id: "elic_claude_fallback", carryingSessionId: "sess_look", title: "Approval requested",
    detail:
      "Claude wants to call **AskUserQuestion**\n\nAskUserQuestion({\"questions\": [{\"question\": \"Which branch should the fix go to?\", \"header\": \"Branch\", \"options\": [], \"multiSelect\": false}]})",
    kind: .approval, phase: "pre_tool_use", policyName: "claude_native_permission",
    acceptsFeedback: true, message: "Claude wants to call **AskUserQuestion**",
    toolInput:
      "AskUserQuestion({\n  \"questions\": [\n    {\n      \"question\": \"Which branch should the fix go to?\",\n      \"header\": \"Branch\",\n      \"options\": [],\n      \"multiSelect\": false\n    }\n  ]\n})"
  )

  /// `Omni--WorkflowRequestInput`: titled by the task waiting on it.
  static let workflowQuestion = DecisionCard(
    id: "elic_workflow", carryingSessionId: "sess_look", title: "Response requested",
    detail: "Waiting for you on Pick the cache store",
    kind: .form(fields: [
      FormField(
        key: "Which store should the session cache use?",
        title: "Which store should the session cache use?", detail: "Cache",
        kind: .singleChoice,
        options: [
          FormOption(value: "Redis (recommended)", detail: "Shared across hosts."),
          FormOption(value: "SQLite", detail: "One file per host."),
        ], allowsCustom: true)
    ]), phase: "workflow_request_input", message: "Waiting for you on Pick the cache store")
}
