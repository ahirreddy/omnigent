import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// Generic data for the screens sweep E changed.
@MainActor
extension SweepLookFixtures {
  /// `Claude--AskUserQuestion--FourQuestions` with the multi-select question skipped: Submit
  /// stays off and names that question.
  static var questionSubmitBlocked: some View {
    let fields = [
      FormField(
        key: "Where should the settings live?", title: "Where should the settings live?",
        detail: "Storage", kind: .singleChoice,
        options: [
          FormOption(value: "A file in the repo", detail: "Reviewed with the code."),
          FormOption(value: "The database", detail: "Editable while the app runs."),
        ], allowsCustom: true),
      FormField(
        key: "Which platforms need the change?", title: "Which platforms need the change?",
        detail: "Platforms", kind: .multipleChoice,
        options: [
          FormOption(value: "Mac", detail: "The desktop app."),
          FormOption(value: "iPhone", detail: "The phone app."),
          FormOption(value: "iPad", detail: "The tablet layout."),
        ], allowsCustom: true),
      FormField(
        key: "How should a failed save be reported?",
        title: "How should a failed save be reported?", detail: "Errors", kind: .singleChoice,
        options: [
          FormOption(value: "A banner", detail: "Stays until dismissed."),
          FormOption(value: "A toast", detail: "Fades after a few seconds."),
        ], allowsCustom: true),
    ]
    let card = DecisionCard(
      id: "elic_four_questions", carryingSessionId: "sess_look", title: "Response requested",
      detail: "Claude wants to call **AskUserQuestion**", kind: .form(fields: fields),
      phase: "pre_tool_use", policyName: "claude_native_permission",
      message: "Claude wants to call **AskUserQuestion**")
    var draft = FormDraft()
    draft.selected = [fields[0].key: ["The database"], fields[2].key: ["A banner"]]
    return LookFixtures.card(card, draft: draft)
  }
}
