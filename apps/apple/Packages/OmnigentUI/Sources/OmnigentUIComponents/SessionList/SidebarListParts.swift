import Foundation
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
          if menu.offersPin {
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

/// A row's hover tooltip: the title, when it was updated, its harness and environment, then
/// the web's details (Created by, Repo, Branch).
nonisolated enum SessionRowTooltip {
  static func text(_ session: SessionSummary, info: SessionRowInfo, now: Date) -> String {
    var lines = [session.title, "Updated \(RelativeTime.short(session.updatedDate, now: now)) ago"]
    if let harness = info.harness { lines.append(HarnessAppearance(harness: harness).label) }
    if let environment = info.environment { lines.append(environment) }
    let details = [
      info.createdBy.map { "Created by: \($0)" }, info.repo.map { "Repo: \($0)" },
      info.branch.map { "Branch: \($0)" },
    ].compactMap { $0 }
    if !details.isEmpty { lines += [""] + details }
    return lines.joined(separator: "\n")
  }
}

/// The sidebar's search field. iPhone and iPad keep one search entry point: where the header's
/// Search opens the palette (titles and message content), the field is left out, so a compact
/// width does not also float a search button beside the list. A sidebar peeking over the
/// content on Mac is outside the split view, so it draws its own field.
struct SidebarSearchField: ViewModifier {
  @Binding var text: String
  @Environment(\.openCommandPalette) private var openPalette
  @Environment(\.isSidebarPeek) private var isPeek

  func body(content: Content) -> some View {
    #if os(iOS)
      if openPalette != nil {
        content
      } else {
        content.searchable(text: $text, placement: .sidebar, prompt: "Search sessions")
      }
    #else
      if isPeek {
        content.safeAreaInset(edge: .top, spacing: 0) {
          TextField("Search sessions", text: $text)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
        }
      } else {
        content.searchable(text: $text, placement: .sidebar, prompt: "Search sessions")
      }
    #endif
  }
}

extension EnvironmentValues {
  /// The sidebar is peeking over the content, outside the split view (Mac).
  @Entry var isSidebarPeek = false
}

/// How many pages the Load more row read by itself in the current scope: the web loads up to
/// three as the row scrolls into view, then waits for a click.
@MainActor
final class SidebarAutoLoads {
  static let limit = 3
  private var scope = ""
  private var count = 0

  /// Counts one automatic load in `scope`; `false` once the scope used its three.
  func take(in scope: String) -> Bool {
    if scope != self.scope {
      self.scope = scope
      count = 0
    }
    guard count < Self.limit else { return false }
    count += 1
    return true
  }
}

/// The web's "Load more" under the sidebar's sessions: it reads the next page as it scrolls
/// into view (up to three times per scope), and on a click.
struct SidebarLoadMoreRow: View {
  let isLoading: Bool
  /// Sessions loaded so far, read out to VoiceOver.
  let loaded: Int
  let autoLoads: SidebarAutoLoads
  let scope: String
  let load: @MainActor () -> Void

  var body: some View {
    Button(action: load) {
      HStack(spacing: Theme.Spacing.small) {
        Spacer(minLength: 0)
        if isLoading {
          ProgressView().controlSize(.small)
          Text("Loading\u{2026}")
        } else {
          Text("Load more")
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .disabled(isLoading)
    .onAppear {
      if !isLoading, autoLoads.take(in: scope) { load() }
    }
    .accessibilityLabel(isLoading ? "Loading more sessions" : "Load more")
    .accessibilityValue("\(loaded) sessions loaded")
    .accessibilityIdentifier("sidebar-load-more")
  }
}
