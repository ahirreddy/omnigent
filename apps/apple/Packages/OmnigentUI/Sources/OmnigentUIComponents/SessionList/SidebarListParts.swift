import Foundation
import SwiftUI

/// What the list shows with no sessions and no projects: loading, no matches, or none.
struct SidebarEmptyState: View {
  let state: SidebarViewState
  let searchText: String
  /// Turns the Running or Needs you filter off with `nil`.
  var setQuickFilter: (@MainActor (SessionFilter?) -> Void)?

  /// What the list says when there is nothing to list.
  enum Content: Equatable {
    case filteredOut(String)
    case loading
    case noMatches(String)
    case empty(String)
    case nothing
  }

  /// What to say. A search or the Archived display that finds nothing says so even beside project
  /// folders; otherwise folders alone are a list, with nothing to explain.
  static func content(state: SidebarViewState, searchText: String) -> Content {
    guard state.list.sessions.isEmpty else { return .nothing }
    if searchText.isEmpty {
      switch state.quickFilter {
      case .running: return .filteredOut("Nothing is running")
      case .needsResponse: return .filteredOut("Nothing needs you")
      case .all, .archived, .none: break
      }
    }
    let showsArchived = state.display.show == .archived
    guard state.projects.isEmpty || !searchText.isEmpty || showsArchived else { return .nothing }
    if case .loading = state.list.phase { return .loading }
    if !searchText.isEmpty { return .noMatches(searchText) }
    return .empty(showsArchived ? "No archived sessions" : "No sessions")
  }

  var body: some View {
    switch Self.content(state: state, searchText: searchText) {
    case .filteredOut(let title):
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Text(title).font(.callout).foregroundStyle(.secondary)
        if let setQuickFilter {
          Button("Show All Sessions") { setQuickFilter(nil) }
            .buttonStyle(.link)
            .font(.callout)
            .accessibilityIdentifier("sidebar-clear-filter")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Theme.Spacing.small)
      .listRowSeparator(.hidden)
    case .loading:
      ProgressView("Loading sessions\u{2026}")
    case .noMatches(let query):
      ContentUnavailableView.search(text: query)
    case .empty(let title):
      ContentUnavailableView(title, systemImage: "bubble.left.and.bubble.right")
        .font(.callout)
        .listRowSeparator(.hidden)
    case .nothing:
      EmptyView()
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

#if os(iOS)
  /// A row's iPhone and iPad swipe actions: read state and pin leading, archive trailing.
  struct SessionSwipeActions: ViewModifier {
    let session: SessionSummary
    let isUnread: Bool
    let menu: SessionRowMenu

    func body(content: Content) -> some View {
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
    }
  }
#endif

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

/// The sidebar's search field. The sidebar makes a new binding with every render and a new
/// binding never compares equal to the last, so the field is a modifier of its own that takes
/// the text and one relay: it updates when the text changes, not with every row.
struct SidebarSearchField: ViewModifier {
  @Binding private var text: String
  @State private var relay: SearchTextRelay

  init(text: Binding<String>) {
    _text = text
    _relay = State(initialValue: SearchTextRelay(text))
  }

  func body(content: Content) -> some View {
    relay.latest = $text
    return content.modifier(SidebarSearchFieldContent(text: text, relay: relay))
  }
}

/// The sidebar's latest search binding, behind a reference that stays the same between renders.
@MainActor
final class SearchTextRelay {
  var latest: Binding<String>

  init(_ latest: Binding<String>) {
    self.latest = latest
  }

  /// Reads and writes through whichever binding is the latest when it is used.
  var binding: Binding<String> {
    Binding(get: { self.latest.wrappedValue }, set: { self.latest.wrappedValue = $0 })
  }
}

/// The field itself. iPhone and iPad keep one search entry point: where the header's Search
/// opens the palette (titles and message content), the field is left out, so a compact width
/// does not also float a search button beside the list. A sidebar peeking over the content on
/// Mac is outside the split view, so it draws its own field.
private struct SidebarSearchFieldContent: ViewModifier {
  /// What the field shows. The body reads it through the relay; a new value is what runs it.
  let text: String
  let relay: SearchTextRelay
  @Environment(\.openCommandPalette) private var openPalette
  @Environment(\.isSidebarPeek) private var isPeek

  func body(content: Content) -> some View {
    field(content).countsRenders("search field")
  }

  @ViewBuilder
  private func field(_ content: Content) -> some View {
    #if os(iOS)
      if openPalette != nil {
        content
      } else {
        content.searchable(text: relay.binding, placement: .sidebar, prompt: "Search sessions")
      }
    #else
      if isPeek {
        content.safeAreaInset(edge: .top, spacing: 0) {
          TextField("Search sessions", text: relay.binding)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
        }
      } else {
        content.searchable(text: relay.binding, placement: .sidebar, prompt: "Search sessions")
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
