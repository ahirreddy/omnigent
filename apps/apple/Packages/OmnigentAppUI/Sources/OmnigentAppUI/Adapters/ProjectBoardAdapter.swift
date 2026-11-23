import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Builds a project board's state from the session list. Which sessions are on the board, their
/// lanes, the family cards, the filter and what a drop does are the core's (`projectBoard`,
/// `boardDropAction`, `boardReadMarks`); this maps them to the page's records.
enum ProjectBoardAdapter {
  /// The board as the core files it now.
  struct Board {
    /// The lanes left to right, filtered.
    var columns: [ProjectBoardColumn]
    /// Every session on the board, filter aside, for its arrivals.
    var sessions: [OmnigentCoreFFI.SessionSummary]
    /// Their ids.
    var sessionIDs: Set<String>
  }

  /// `project`'s board from the loaded sessions, with each card's preview from `previews`.
  /// - Parameters:
  ///   - project: The project.
  ///   - list: The session list.
  ///   - filter: The filter's text.
  ///   - previews: Reply previews by session id.
  /// - Returns: The board.
  static func board(
    project: ProjectSummary, list: SessionListStore, filter: String, previews: [String: String]
  ) -> Board {
    let sessions = Array(list.sessionsByID.values)
    let unread = list.unreadIDs
    let drafts = list.draftSessionIDs
    let file = { (query: String) in
      projectBoard(
        project: project, sessions: sessions, unreadIds: Array(unread), draftIds: Array(drafts),
        viewerId: list.viewerID, query: query)
    }
    let all = file("")
    let shown = filter.trimmingCharacters(in: .whitespaces).isEmpty ? all : file(filter)
    let memberIDs = Set(all.flatMap(\.cards).flatMap(\.memberIds))
    let attention = list.attentionByID
    let idle = SessionAttention(state: .idle, requests: 0)
    let columns = shown.map { column in
      ProjectBoardColumn(
        lane: lane(column.lane),
        cards: column.cards.compactMap { card -> ProjectBoardCard? in
          guard let head = list.sessionsByID[card.sessionId] else { return nil }
          let headAttention = attention[head.id] ?? idle
          return ProjectBoardCard(
            session: OmnigentUIComponents.SessionSummary(head, attention: headAttention),
            info: SidebarAdapter.rowInfo(
              head, isOwned: list.isOwned(head), environments: list.hostEnvironments,
              hasDraft: drafts.contains(head.id), lookup: { list.sessionsByID[$0] }),
            memberIDs: card.memberIds, lane: lane(card.lane),
            isUnread: card.memberIds.contains { unread.contains($0) },
            requests: SidebarAdapter.requests(headAttention) ?? 0, preview: previews[head.id])
        })
    }
    return Board(
      columns: columns, sessions: sessions.filter { memberIDs.contains($0.id) },
      sessionIDs: memberIDs)
  }

  /// Where the board's sessions stand: its folder's first page loading, failed or read.
  static func phase(_ folderID: String, paging: SessionListPaging) -> ProjectBoardPhase {
    if let failure = paging.folderFailures[folderID] { return .failed(message: failure.message) }
    return paging.projects[folderID]?.isLoaded == true ? .loaded : .loading
  }

  /// The sessions whose read state a card's Mark as read (`unread` false) or Mark as unread
  /// changes: every unread member, or the head.
  static func readMarks(_ card: ProjectBoardCard, unread: Bool, list: SessionListStore)
    -> [String]
  {
    boardReadMarks(
      card: BoardCard(sessionId: card.id, memberIds: card.memberIDs, lane: lane(card.lane)),
      action: unread ? .markUnread : .markRead, unreadIds: Array(list.unreadIDs))
  }

  /// A project as the board names it: its folder.
  static func folder(_ project: ProjectSummary) -> SessionProject {
    SessionProject(
      id: projectFolderId(project: project), name: project.name, sessionIds: [],
      projectID: project.id, icon: project.icon)
  }

  static func lane(_ lane: BoardLane) -> ProjectBoardLane {
    switch lane {
    case .draft: .draft
    case .needsAttention: .needsAttention
    case .working: .working
    case .unread: .unread
    case .done: .done
    }
  }

  static func lane(_ lane: ProjectBoardLane) -> BoardLane {
    switch lane {
    case .draft: .draft
    case .needsAttention: .needsAttention
    case .working: .working
    case .unread: .unread
    case .done: .done
    }
  }
}
