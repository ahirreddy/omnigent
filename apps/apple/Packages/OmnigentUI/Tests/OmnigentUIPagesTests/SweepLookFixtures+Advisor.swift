import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// Generic data for Omni Advisor's screens: the Inbox's tab and Settings.
@MainActor
extension SweepLookFixtures {
  /// The Inbox on Omni Advisor's tab, its suggestion open; empty when `empty`.
  static func advisorInbox(empty: Bool) -> some View {
    UserDefaults.standard.set(InboxFilter.advisor.rawValue, forKey: InboxView.filterKey)
    var item = InboxItem(
      id: "suggestion-advisor", kind: .suggestion, sessionId: "hidden",
      sessionTitle: "Follow up on the flaky upload test",
      preview: "The retry fix landed, but the upload test still fails on slow hosts.",
      date: now.addingTimeInterval(-1_800))
    item.suggestion = InboxSuggestion(
      kindLabel: "Omni Advisor \u{00B7} Suggested follow-up",
      title: "Follow up on the flaky upload test",
      body: "The retry fix landed, but the upload test still fails on slow hosts.",
      links: [InboxLink(title: "Open session", sessionID: "abc")],
      actions: ["Investigate the test", "Later"],
      dismissChoices: [InboxDismissChoice(id: "not_now", title: "Not now")], isAdvisor: true)
    var other = InboxItem(
      id: "suggestion-other", kind: .suggestion, sessionId: "abc", sessionTitle: "Ship notes",
      preview: "Draft the release notes.", date: now.addingTimeInterval(-3_600))
    other.suggestion = InboxSuggestion(
      kindLabel: "Reminder", title: "Ship notes", body: "Draft the release notes.")
    var actions = InboxActions(open: { _ in }, markRead: { _ in })
    actions.takeSuggestionAction = { _, _ in }
    actions.dismissSuggestion = { _, _ in }
    actions.openLink = { _ in }
    var state = InboxViewState(items: empty ? [other] : [item, other], now: now)
    state.advisorTab = .shown
    return InboxView(state: state, actions: actions)
  }

  /// Settings › Omni Advisor, the caller's switch on.
  static var advisorSettings: some View {
    var actions = AdvisorActions()
    actions.setEnabled = { _, _ in }
    return Form {
      AdvisorSettingsPane(
        state: AdvisorViewState(
          settings: .ready(
            AdvisorSwitches(userOn: true, workspaceEnabled: true, canManageWorkspace: true))),
        actions: actions)
      AdvisorSettingsPane(
        state: AdvisorViewState(
          settings: .ready(
            AdvisorSwitches(userOn: false, workspaceEnabled: false, canManageWorkspace: false))),
        actions: actions)
    }
    .formStyle(.grouped)
  }

  /// Admin › General's Omni Advisor groups: the workspace switch, a custom prompt and the last
  /// Run now.
  static var advisorAdmin: some View {
    var actions = AdvisorActions()
    actions.setEnabled = { _, _ in }
    actions.savePrompt = { $0 }
    actions.run = { _ in }
    let state = AdvisorViewState(
      settings: .ready(
        AdvisorSwitches(userOn: true, workspaceEnabled: true, canManageWorkspace: true)),
      prompt: .ready(
        prompt: "Read the user's sessions from the last day.\nPost at most three items.",
        overridden: true),
      runSummary: "Started 1 run. Skipped: bo@example.com (already running).")
    return Form { AdvisorAdminSections(state: state, actions: actions) }
      .formStyle(.grouped)
  }
}
