import SwiftUI

/// The Inbox feeds beside the sessions that failed to load or to save, each with its Retry.
struct InboxFeedBanners: View {
  let state: InboxViewState
  let actions: InboxActions
  let filter: InboxFilter

  var body: some View {
    if state.suggestionWriteFailed {
      Label(
        "Couldn\u{2019}t save your response to this suggestion. Try again.",
        systemImage: "exclamationmark.triangle"
      )
      .font(.callout).foregroundStyle(.red)
      .accessibilityIdentifier("inbox-suggestion-write-error")
    }
    if state.suggestionsFailed {
      banner(
        "Couldn\u{2019}t load suggestions.", retry: "Retry suggestions",
        action: actions.retrySuggestions, id: "inbox-suggestions-error")
    }
    if state.automationsFailed, filter != .awaiting {
      banner(
        "Couldn\u{2019}t load automation failures.", retry: "Retry automations",
        action: actions.retryAutomations, id: "inbox-automations-error")
    }
  }

  private func banner(
    _ message: String, retry: String, action: (@MainActor () -> Void)?, id: String
  ) -> some View {
    HStack {
      Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      Spacer()
      if let action { Button(retry, action: action) }
    }
    .font(.callout)
    .accessibilityIdentifier(id)
  }
}

/// "Load more suggestions" and, on All and Unread, "Check more automations".
struct InboxFeedPaging: View {
  let state: InboxViewState
  let actions: InboxActions
  let filter: InboxFilter

  var body: some View {
    if state.hasMoreSuggestions, filter != .awaiting, let loadMore = actions.loadMoreSuggestions {
      row(
        "Load more suggestions", isLoading: state.isLoadingMoreSuggestions, action: loadMore,
        id: "inbox-load-more-suggestions")
    }
    if state.hasMoreAutomations, filter != .awaiting, let loadMore = actions.loadMoreAutomations {
      row(
        "Check more automations", isLoading: state.isLoadingMoreAutomations, action: loadMore,
        id: "inbox-check-more-automations")
    }
  }

  private func row(
    _ title: String, isLoading: Bool, action: @escaping @MainActor () -> Void, id: String
  ) -> some View {
    Button(isLoading ? "Loading\u{2026}" : title, action: action)
      .buttonStyle(.bordered)
      .disabled(isLoading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listRowSeparator(.hidden)
      .accessibilityIdentifier(id)
  }
}
