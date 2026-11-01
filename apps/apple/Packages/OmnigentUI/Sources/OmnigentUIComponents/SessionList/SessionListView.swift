import OmnigentPlatform
public import SwiftUI

/// The session sidebar: filters with counts, search, pinned and date-grouped sessions with
/// status, unread and attention badges, context menus, swipe actions and keyboard navigation
/// (arrow keys move the selection; Delete archives on Mac).
public struct SessionListView: View {
  private let state: SessionListViewState
  @Binding private var selection: String?
  @Binding private var searchText: String
  private let actions: SessionListActions

  @State private var renaming: SessionSummary?
  @State private var renameText = ""

  /// Creates the list.
  /// - Parameters:
  ///   - state: Sessions, filter and badges.
  ///   - selection: The selected session id.
  ///   - searchText: The search text; the host re-queries the core as it changes.
  ///   - actions: Host actions.
  public init(
    state: SessionListViewState, selection: Binding<String?>, searchText: Binding<String>,
    actions: SessionListActions
  ) {
    self.state = state
    _selection = selection
    _searchText = searchText
    self.actions = actions
  }

  /// The list.
  public var body: some View {
    List(selection: $selection) {
      if actions.setFilter != nil {
        Section {
          ForEach(SessionFilter.allCases) { filter in
            FilterRow(
              filter: filter, isActive: filter == state.filter, count: state.filterCounts[filter]
            ) {
              actions.setFilter?(filter)
            }
          }
        }
      }
      ForEach(SessionGrouping.groups(state.sessions, now: state.now ?? Date())) { group in
        Section(group.title) {
          ForEach(group.sessions) { session in
            SessionRow(
              session: session, isUnread: state.unreadIds.contains(session.id),
              attention: state.attentionCounts[session.id] ?? 0,
              now: state.now ?? Date()
            )
            .tag(session.id)
            .contextMenu { contextMenu(for: session) }
            #if os(iOS)
              .swipeActions(edge: .leading) { leadingSwipe(session) }
              .swipeActions(edge: .trailing) { trailingSwipe(session) }
            #endif
          }
        }
      }
    }
    .listStyle(.sidebar)
    .searchable(text: $searchText, placement: .sidebar, prompt: "Search sessions")
    .overlay { emptyState }
    .safeAreaInset(edge: .bottom, spacing: 0) { failureBar }
    #if os(macOS)
      .onDeleteCommand {
        guard let selected, selected.canArchive, let setArchived = actions.setArchived else {
          return
        }
        setArchived(selected, !selected.isArchived)
      }
    #endif
    .alert(
      "Rename Session",
      isPresented: Binding(
        get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField("Title", text: $renameText)
      Button("Rename") {
        if let renaming, let rename = actions.rename {
          rename(renaming, renameText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        renaming = nil
      }
      .disabled(
        renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameText.count > 120
      )
      Button("Cancel", role: .cancel) { renaming = nil }
    } message: {
      Text("Titles can be up to 120 characters.")
    }
    .accessibilityIdentifier("session-list")
  }

  private var selected: SessionSummary? {
    guard let selection else { return nil }
    return state.sessions.first { $0.id == selection }
  }

  @ViewBuilder private var emptyState: some View {
    if state.sessions.isEmpty {
      switch state.phase {
      case .loading:
        ProgressView("Loading sessions")
      case .loaded, .failed:
        if searchText.isEmpty {
          ContentUnavailableView {
            Label(emptyTitle, systemImage: state.filter.systemImage)
          } description: {
            Text(emptyDescription)
          } actions: {
            if let newSession = actions.newSession, state.filter == .all {
              Button("New Session", action: newSession)
            }
          }
        } else {
          ContentUnavailableView.search(text: searchText)
        }
      }
    }
  }

  private var emptyTitle: String {
    switch state.filter {
    case .all: "No Sessions"
    case .running: "Nothing Running"
    case .needsResponse: "Nothing Needs You"
    case .archived: "No Archived Sessions"
    }
  }

  private var emptyDescription: String {
    switch state.filter {
    case .all: "Start a session to work with an agent."
    case .running: "Sessions with a turn in progress appear here."
    case .needsResponse: "Sessions waiting for an approval or an answer appear here."
    case .archived: "Archived sessions appear here."
    }
  }

  @ViewBuilder private var failureBar: some View {
    if case .failed(let message) = state.phase {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(Theme.failure)
          .accessibilityHidden(true)
        Text(message)
          .font(.caption)
          .lineLimit(3)
          .textSelection(.enabled)
        Spacer(minLength: 4)
        if let retry = actions.retry {
          Button("Retry", action: retry).controlSize(.small)
        }
      }
      .padding(10)
      .background(.bar)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Sessions could not load: \(message)")
      .accessibilityIdentifier("session-list-error")
    }
  }

  @ViewBuilder
  private func contextMenu(for session: SessionSummary) -> some View {
    if let open = actions.openInNewWindow {
      Button("Open in New Window", systemImage: "macwindow.badge.plus") { open(session) }
      Divider()
    }
    if let webURL = actions.webURL?(session) {
      Button("Copy Link", systemImage: "link") { Pasteboard.copy(webURL.absoluteString) }
    }
    Button("Copy Session ID", systemImage: "number") { Pasteboard.copy(session.id) }
    Divider()
    if let setPinned = actions.setPinned, session.canPin {
      Button(
        session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin"
      ) {
        setPinned(session, !session.isPinned)
      }
    }
    if let setUnread = actions.setUnread {
      let unread = state.unreadIds.contains(session.id)
      Button(
        unread ? "Mark as Read" : "Mark as Unread",
        systemImage: unread ? "envelope.open" : "envelope.badge"
      ) {
        setUnread(session, !unread)
      }
    }
    if actions.rename != nil, session.canRename {
      Button("Rename\u{2026}", systemImage: "pencil") {
        renameText = session.title
        renaming = session
      }
    }
    if let setArchived = actions.setArchived, session.canArchive {
      Divider()
      Button(
        session.isArchived ? "Restore" : "Archive",
        systemImage: session.isArchived ? "tray.and.arrow.up" : "archivebox"
      ) {
        setArchived(session, !session.isArchived)
      }
    }
  }

  #if os(iOS)
    @ViewBuilder
    private func leadingSwipe(_ session: SessionSummary) -> some View {
      if let setUnread = actions.setUnread {
        let unread = state.unreadIds.contains(session.id)
        Button(unread ? "Read" : "Unread", systemImage: unread ? "envelope.open" : "envelope.badge")
        {
          setUnread(session, !unread)
        }
        .tint(Theme.unread)
      }
      if let setPinned = actions.setPinned, session.canPin {
        Button(session.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
          setPinned(session, !session.isPinned)
        }
        .tint(.orange)
      }
    }

    @ViewBuilder
    private func trailingSwipe(_ session: SessionSummary) -> some View {
      if let setArchived = actions.setArchived, session.canArchive {
        Button(session.isArchived ? "Restore" : "Archive", systemImage: "archivebox") {
          setArchived(session, !session.isArchived)
        }
        .tint(.indigo)
      }
    }
  #endif
}
