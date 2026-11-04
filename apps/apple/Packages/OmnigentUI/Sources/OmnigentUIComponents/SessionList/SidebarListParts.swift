import SwiftUI

/// What the list shows with no sessions and no projects: loading, no matches, or none.
struct SidebarEmptyState: View {
  let state: SidebarViewState
  let searchText: String

  var body: some View {
    if state.list.sessions.isEmpty, state.projects.isEmpty {
      switch state.list.phase {
      case .loading:
        ProgressView("Loading sessions\u{2026}")
      case .loaded, .failed:
        if !searchText.isEmpty {
          ContentUnavailableView.search(text: searchText)
        } else {
          ContentUnavailableView(
            state.display.show == .archived ? "No archived sessions" : "No sessions",
            systemImage: "bubble.left.and.bubble.right"
          )
          .font(.callout)
          .listRowSeparator(.hidden)
        }
      }
    }
  }
}

/// The list's load failure, with Retry, under the sidebar.
struct SessionListErrorBar: View {
  let message: String
  let retry: (@MainActor () -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(Theme.failure)
        .accessibilityHidden(true)
      Text(message).font(.caption).lineLimit(3).textSelection(.enabled)
      Spacer(minLength: 4)
      if let retry {
        Button("Retry", action: retry).controlSize(.small)
          .accessibilityIdentifier("session-list-retry")
      }
    }
    .padding(Theme.Spacing.medium)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("session-list-error")
  }
}

/// A row's iPhone and iPad swipe actions: read state and pin leading, archive trailing.
struct SessionSwipeActions: ViewModifier {
  let session: SessionSummary
  let isUnread: Bool
  let menu: SessionRowMenu

  func body(content: Content) -> some View {
    #if os(iOS)
      content
        .swipeActions(edge: .leading) {
          if let setUnread = menu.actions.setUnread {
            Button(
              isUnread ? "Read" : "Unread",
              systemImage: isUnread ? "envelope.open" : "envelope.badge"
            ) {
              setUnread(session, !isUnread)
            }
            .tint(Theme.unread)
          }
          if menu.actions.setPinned != nil, session.canPin {
            Button(session.isPinned ? "Unpin" : "Pin", systemImage: "pin") { menu.togglePin() }
              .tint(.orange)
          }
        }
        .swipeActions(edge: .trailing) {
          if let setArchived = menu.actions.setArchived, session.canArchive {
            Button(session.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") {
              setArchived(session, !session.isArchived)
            }
            .tint(.indigo)
          }
        }
    #else
      content
    #endif
  }
}
