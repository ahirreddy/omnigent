import SwiftUI

/// Stateful sample triage: three requests in two sessions, a pinned update, and an optional
/// failed response.
struct InboxTriagePlayground: View {
  @State private var state = InboxTriageSamples.state
  @State private var failNextResponse = false
  @State private var opened: InboxItem?

  var body: some View {
    InboxView(
      state: state,
      actions: InboxActions(
        open: { opened = $0 },
        markRead: { item in
          if let index = state.items.firstIndex(where: { $0.id == item.id }) {
            state.items[index].isUnread = false
          }
        },
        respond: { card, response in
          guard let index = state.items.firstIndex(where: { $0.decision?.id == card.id }) else {
            return
          }
          if failNextResponse {
            state.items[index].phase = .failed(
              message: "The host is offline. Reconnect and try again.")
            failNextResponse = false
          } else {
            state.items[index].phase = .answered(summary: response.summary)
            state.items[index].isUnread = false
            state.needsYouCount = InboxTriageSamples.sessionsNeedingYou(state.items)
          }
        })
    )
    .toolbar {
      ToolbarItem {
        Toggle("Fail next response", isOn: $failNextResponse)
          .accessibilityIdentifier("inbox-sample-fail-next")
      }
    }
    .sheet(item: $opened) { item in
      VStack(spacing: Theme.Spacing.medium) {
        Text(item.sessionTitle).font(.title2)
        Text(item.preview)
        Button("Back to Inbox") { opened = nil }
          .accessibilityIdentifier("inbox-sample-back")
      }
      .padding(Theme.Spacing.extraLarge)
    }
  }
}

enum InboxTriageSamples {
  static var state: InboxViewState {
    var state = PreviewData.inbox
    for index in state.items.indices {
      state.items[index].agentName = index.isMultiple(of: 2) ? "Codex" : "Claude Code"
      state.items[index].executionContext = "Mac Studio · omnigent / auth-refresh"
      if state.items[index].decision != nil {
        state.items[index].waitingSince = state.items[index].date
      }
    }
    state.items[0].preview =
      PreviewData.codexCommand.permissions.command?.command ?? state.items[0].preview
    state.items[1].isUnread = false
    state.items[3].isPinned = true
    // A second request in the first request's session: three requests, two sessions.
    var question = InboxItem(
      id: "in5", kind: .question, sessionId: "sess_a2",
      sessionTitle: "Fix flaky SSE reconnect test",
      preview: "Should the reconnect test keep the last server between runs?",
      date: PreviewData.now.addingTimeInterval(-180),
      decision: DecisionCard(
        id: "triage-question", carryingSessionId: "sess_a2", title: "Keep the server?",
        detail: "Should the reconnect test keep the last server between runs?",
        kind: .choice(answerKey: "answer", options: ["Keep it between runs", "Start fresh"])))
    question.agentName = "Claude Code"
    question.executionContext = "Build Mac · omnigent / sign-in"
    question.waitingSince = question.date
    state.items.insert(question, at: 2)
    state.needsYouCount = sessionsNeedingYou(state.items)
    return state
  }

  /// Sessions with an unresolved request, as the shared attention model counts them (sessions,
  /// not requests).
  static func sessionsNeedingYou(_ items: [InboxItem]) -> Int {
    Set(items.filter { $0.decision != nil && $0.isUnresolved }.map(\.sessionId)).count
  }
}
