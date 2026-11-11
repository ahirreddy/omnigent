import Foundation

/// Everything one sidebar row draws for its session.
nonisolated public struct SidebarRowContent: Hashable, Sendable {
  /// The session, with its attention.
  public var session: SessionSummary
  /// Facts the summary lacks.
  public var info: SessionRowInfo
  /// It has activity the user has not seen.
  public var isUnread: Bool
  /// Pending decisions the user can answer; `nil` when it does not need them.
  public var requests: Int?

  /// Creates a row's content.
  /// - Parameters:
  ///   - session: The session.
  ///   - info: Facts the summary lacks.
  ///   - isUnread: Unread.
  ///   - requests: Pending decisions.
  public init(
    session: SessionSummary, info: SessionRowInfo = SessionRowInfo(), isUnread: Bool = false,
    requests: Int? = nil
  ) {
    self.session = session
    self.info = info
    self.isUnread = isUnread
    self.requests = requests
  }
}

/// The counts on the sidebar's top rows.
nonisolated public struct SidebarCounts: Hashable, Sendable {
  /// The Inbox badge.
  public var inbox: Int
  /// The quick filters' counts. A missing filter shows none.
  public var filters: [SessionFilter: Int]

  /// Creates counts.
  /// - Parameters:
  ///   - inbox: The Inbox badge.
  ///   - filters: The quick filters' counts.
  public init(inbox: Int = 0, filters: [SessionFilter: Int] = [:]) {
    self.inbox = inbox
    self.filters = filters
  }
}

/// What the sidebar reads as it is now instead of from its state, so that one session's new text,
/// status or mark draws that session's row and not the list. Each reader is called in the body of
/// the view that shows the value, which is then the only view the value's change draws again.
public struct SidebarLive {
  /// One session's row; `nil` once the session is gone. Its draft is read only when
  /// `showsDraft`, so a row that hides the mark is not drawn for it.
  public var row: @MainActor (_ sessionID: String, _ showsDraft: Bool) -> SidebarRowContent?
  /// The counts on the top rows.
  public var counts: @MainActor () -> SidebarCounts

  /// Creates the readers.
  /// - Parameters:
  ///   - row: One session's row.
  ///   - counts: The top rows' counts.
  public init(
    row: @escaping @MainActor (_ sessionID: String, _ showsDraft: Bool) -> SidebarRowContent?,
    counts: @escaping @MainActor () -> SidebarCounts
  ) {
    self.row = row
    self.counts = counts
  }
}

extension SidebarViewState {
  /// A session's row as this state has it: what is drawn without ``SidebarLive``.
  /// - Parameter session: The session.
  /// - Returns: Its row.
  public func rowContent(_ session: SessionSummary) -> SidebarRowContent {
    SidebarRowContent(
      session: session, info: rowInfo[session.id] ?? SessionRowInfo(),
      isUnread: list.unreadIds.contains(session.id), requests: list.attentionCounts[session.id])
  }

  /// The top rows' counts as this state has them.
  public var counts: SidebarCounts {
    SidebarCounts(inbox: inboxCount, filters: list.filterCounts)
  }
}

/// The sidebar's sections and the order of their rows: what only drawing the list can change.
nonisolated public struct SidebarArrangement: Equatable, Sendable {
  private var titles: [String]
  private var rows: [[String]]

  /// The arrangement `state` draws.
  /// - Parameter state: The sidebar's state.
  public init(_ state: SidebarViewState) {
    let sections = SidebarSections.sections(state)
    titles = sections.map(\.title)
    rows = sections.map { $0.sessions.map(\.id) }
  }
}
