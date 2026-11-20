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

  /// Sidebar rows beside a muted one: its title dims and a bell stands in for its age.
  static var mutedRows: some View {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func row(_ id: String, _ title: String, muted: Bool, unread: Bool = false) -> some View {
      var session = SessionSummary(
        id: id, title: title, updatedAt: 1_800_000_000 - 600,
        attention: unread ? .unread : .idle)
      session.isMuted = muted
      let menu = SessionRowMenu(
        session: session, isUnread: unread, isShared: false, pinLimitReached: false,
        projects: [], actions: SessionListActions(), rename: {}, confirmDelete: {},
        confirmLeave: {}, confirmStop: {})
      return SessionRow(
        session: session, info: SessionRowInfo(), isUnread: unread, attention: 0,
        details: [.updated], now: now, menu: menu)
    }
    return List {
      row("a", "Fix the flaky upload test", muted: false, unread: true)
      row("b", "Nightly dependency bumps", muted: true)
      row("c", "Draft the release notes", muted: false)
    }
    .listStyle(.sidebar)
  }
}
