import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// A project's board from the session list: the core's lanes, cards and filter mapped to the
/// page, its loading state, its read marks and the new arrivals it outlines.
@MainActor
@Suite("Project board mapping")
struct ProjectBoardAdapterTests {
  private typealias Fixtures = ConversationFixtures
  private let project = ProjectSummary(id: "p1", name: "Docs", icon: nil)

  private func filed(
    _ id: String, status: OmnigentCoreFFI.SessionListStatus = .idle, updatedAt: Int64
  ) -> OmnigentCoreFFI.SessionSummary {
    var session = Fixtures.summary(id, status: status, updatedAt: updatedAt, title: id)
    session.projectId = "p1"
    return session
  }

  @Test("The project's loaded sessions go in their lanes by status, read marks and drafts")
  func lanes() async throws {
    let connection = try await Fixtures.connection()
    let list = connection.sessionList
    list.apply(
      .reset(sessions: [
        filed("done", updatedAt: 1), filed("unread", updatedAt: 2), filed("draft", updatedAt: 3),
        filed("running", status: .running, updatedAt: 4),
        Fixtures.summary("elsewhere", updatedAt: 5),
      ]))
    list.unreadIDs = ["unread"]
    list.draftSessionIDs = ["draft"]
    let board = ProjectBoardAdapter.board(
      project: project, list: list, filter: "", previews: ["done": "All set."])
    #expect(board.columns.map(\.lane) == ProjectBoardLane.allCases)
    #expect(
      board.columns.map { $0.cards.map(\.id) } == [
        ["draft"], [], ["running"], ["unread"], ["done"],
      ])
    #expect(board.columns[4].cards.first?.preview == "All set.")
    #expect(board.columns[3].cards.first?.isUnread == true)
    #expect(board.columns[0].cards.first?.info.hasDraft == true)
    #expect(board.sessionIDs == ["done", "unread", "draft", "running"])

    let filtered = ProjectBoardAdapter.board(
      project: project, list: list, filter: " UNR ", previews: [:])
    #expect(filtered.columns.flatMap(\.cards).map(\.id) == ["unread"])
    #expect(filtered.sessionIDs.count == 4, "arrivals watch the whole board, filter aside")

    let card = try #require(board.columns[3].cards.first)
    #expect(ProjectBoardAdapter.readMarks(card, unread: false, list: list) == ["unread"])
    #expect(ProjectBoardAdapter.readMarks(card, unread: true, list: list) == ["unread"])
    let lanes = ProjectBoardLane.allCases
    #expect(lanes.map { ProjectBoardAdapter.lane(ProjectBoardAdapter.lane($0)) } == lanes)
  }

  @Test("A folder not read yet loads, a read one shows, a failed one says why")
  func phases() {
    let paging = SessionListPaging()
    #expect(ProjectBoardAdapter.phase("p1", paging: paging) == .loading)
    paging.foldersChanged([
      ProjectFolderPaging(folderId: "p1", isLoaded: true, hasMoreAfter: false, isLoading: false)
    ])
    #expect(ProjectBoardAdapter.phase("p1", paging: paging) == .loaded)
    paging.folderFailed("p1", .InvalidState(message: "boom"))
    guard case .failed = ProjectBoardAdapter.phase("p1", paging: paging) else {
      Issue.record("a failed read shows")
      return
    }
  }

  @Test("New sessions are outlined; those on the board when it loads are not")
  func arrivals() {
    let arrivals = ProjectBoardArrivals()
    let now = Int64(Date().timeIntervalSince1970)
    var old = filed("old", updatedAt: now)
    old.createdAt = now - 3_600
    var fresh = filed("fresh", updatedAt: now)
    fresh.createdAt = now
    var paged = filed("paged", updatedAt: now)
    paged.createdAt = now - 86_400
    arrivals.update(["old"], sessions: [old])
    #expect(arrivals.highlighted.isEmpty)
    arrivals.update(["old", "fresh", "paged"], sessions: [old, fresh, paged])
    #expect(arrivals.highlighted == ["fresh"])
  }

  @Test("A board's folder converts to the sidebar's, by its folder id")
  func folder() {
    let folder = ProjectBoardAdapter.folder(
      ProjectSummary(id: nil, name: "Label", icon: "\u{1F4DA}"))
    #expect(folder.id == "label:Label")
    #expect(folder.projectID == nil)
    #expect(folder.icon == "\u{1F4DA}")
  }
}
