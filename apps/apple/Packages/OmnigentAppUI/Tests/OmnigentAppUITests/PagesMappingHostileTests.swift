import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import Testing

@testable import OmnigentAppUI

/// Lists a page after page without end, like a server whose cursor never runs out.
private final class EndlessDirectory: WorkspaceDataSource {
  var reads = 0
  private var failure: OmnigentWorkspaceUI.WorkspaceFailure {
    OmnigentWorkspaceUI.WorkspaceFailure(.unavailable, message: "")
  }

  func listDirectory(_ path: String, after cursor: String?) throws(OmnigentWorkspaceUI
    .WorkspaceFailure)
    -> OmnigentWorkspaceUI.DirectoryPage
  {
    reads += 1
    let entries = [
      OmnigentWorkspaceUI.WorkspaceEntry(path: "\(path)/file", kind: .file),
      OmnigentWorkspaceUI.WorkspaceEntry(path: "\(path)/folder", kind: .directory),
      OmnigentWorkspaceUI.WorkspaceEntry(path: "\(path)/file", kind: .file),
    ]
    return OmnigentWorkspaceUI.DirectoryPage(
      directory: path, entries: entries, nextCursor: cursor ?? "same")
  }

  func readFile(_ path: String) throws(OmnigentWorkspaceUI.WorkspaceFailure)
    -> OmnigentWorkspaceUI.WorkspaceFile
  { throw failure }
  func searchPaths(_ query: String, include: String, exclude: String)
    throws(OmnigentWorkspaceUI.WorkspaceFailure) -> OmnigentWorkspaceUI.PathSearchResult
  { throw failure }
  func searchContent(_ query: OmnigentWorkspaceUI.ContentSearchQuery)
    throws(OmnigentWorkspaceUI.WorkspaceFailure)
    -> OmnigentWorkspaceUI.ContentSearchResult
  { throw failure }
  func changes() throws(OmnigentWorkspaceUI.WorkspaceFailure)
    -> OmnigentWorkspaceUI.ChangesList
  { throw failure }
  func diff(_ path: String) throws(OmnigentWorkspaceUI.WorkspaceFailure)
    -> OmnigentWorkspaceUI.FileDiff
  { throw failure }
  func absoluteLocation(of path: String) -> String? { nil }
  func save(_ path: String, text: String, base: String?) throws(OmnigentWorkspaceUI
    .WorkspaceFailure)
    -> OmnigentWorkspaceUI.FileSaveResult
  { throw failure }
  func comments(on path: String, text: String) throws(OmnigentWorkspaceUI.WorkspaceFailure)
    -> [OmnigentWorkspaceUI.FileCommentLine]
  { throw failure }
  func addComment(_ body: String, on span: OmnigentWorkspaceUI.FileTextSpan)
    throws(OmnigentWorkspaceUI.WorkspaceFailure)
  {
    throw failure
  }
  // swiftlint:disable:next discouraged_optional_boolean
  func updateComment(_ id: String, body: String?, open: Bool?) throws(OmnigentWorkspaceUI
    .WorkspaceFailure)
  {
    throw failure
  }
  func deleteComment(_ id: String) throws(OmnigentWorkspaceUI.WorkspaceFailure) {
    throw failure
  }
  func sendCommentsToAgent(_ ids: [String]) throws(OmnigentWorkspaceUI.WorkspaceFailure) {
    throw failure
  }
}

@MainActor
@Suite("Page mappings from hostile data")
struct PagesMappingHostileTests {
  private typealias Fixtures = ConversationFixtures
  private let now = Date(timeIntervalSince1970: 1_793_865_600)

  private func usageSession(
    id: String = "s", cost: Double = 1, updatedAt: Int64 = 1_793_865_600, models: [ModelCost] = []
  ) -> SessionUsage {
    SessionUsage(
      id: id, title: nil, createdAt: updatedAt, updatedAt: updatedAt, costUsd: cost,
      models: models, harness: nil)
  }

  private func usage(_ report: UsageReport, window: UsageMapping.Window? = nil) -> UsageViewState {
    UsageMapping.state(
      .loaded(report), window: window ?? UsageMapping.Window(range: .all), now: now)
  }

  @Test("Usage waits, fails, or shows an empty report")
  func usageLoads() {
    let window = UsageMapping.Window(range: .all)
    #expect(UsageMapping.state(.idle, window: window, now: now).isLoading)
    let failed = UsageMapping.state(
      .failed(.InvalidState(message: "no")), window: window, now: now)
    #expect(!failed.isLoading)
    #expect(failed.loadError == "no")
    let empty = usage(UsageReport(dailyCosts: [], sessions: []))
    #expect(empty.sessions.isEmpty)
    #expect(!empty.isLoading)
    #expect(empty.totalText.contains("0"))
  }

  @Test(
    "Costs that aren't real numbers still format",
    arguments: [
      Double.nan, .infinity, -.infinity, -1, 0, 1e300, -1e300, .leastNonzeroMagnitude,
    ])
  func oddCosts(cost: Double) {
    let view = usage(
      UsageReport(
        dailyCosts: [DailyCost(day: "2026-11-05", costUsd: cost)],
        sessions: [usageSession(cost: cost)]))
    #expect(!view.totalText.isEmpty)
    #expect(view.sessions.first?.costText.isEmpty == false)
  }

  @Test("Usage rows read at both ends of the 64-bit range and with odd model lists")
  func usageRows() {
    let model = ModelCost(model: "", costUsd: .nan)
    let view = usage(
      UsageReport(
        dailyCosts: [
          DailyCost(day: "", costUsd: 1), DailyCost(day: "exploded", costUsd: 1),
          DailyCost(day: "2026-11-05", costUsd: 1), DailyCost(day: "2026-11-05", costUsd: 1),
        ],
        sessions: [
          usageSession(id: "none", updatedAt: .min), usageSession(id: "one", models: [model]),
          usageSession(id: "two", updatedAt: .max, models: [model, model]),
          usageSession(id: "repeat"), usageSession(id: "repeat"),
        ]))
    let rows = Dictionary(
      view.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    #expect(rows["none"]?.model == "\u{2014}")
    #expect(rows["none"]?.title == "Untitled")
    #expect(rows["none"]?.updatedAt == Date(timeIntervalSince1970: TimeInterval(Int64.min)))
    #expect(rows["one"]?.model.isEmpty == true)
    #expect(rows["two"]?.model == " +1")
    #expect(view.sessions.filter { $0.id == "repeat" }.count == 2)
  }

  @Test("Windows bound custom days only when both ends are chosen")
  func usageWindows() {
    #expect(UsageMapping.bounds(UsageMapping.Window(range: .all), now: now).0 == nil)
    #expect(UsageMapping.bounds(UsageMapping.Window(range: .custom), now: now).0 == nil)
    #expect(
      UsageMapping.bounds(UsageMapping.Window(range: .custom, start: now, end: nil), now: now).1
        == nil)
    for range in [UsageRange.week, .month, .quarter] {
      let bounds = UsageMapping.bounds(UsageMapping.Window(range: range), now: now)
      #expect(bounds.0?.count == 10)
      #expect(bounds.1 == nil)
    }
    let bounds = UsageMapping.bounds(
      UsageMapping.Window(range: .custom, start: .distantPast, end: .distantFuture), now: now)
    #expect(bounds.0 != nil)
    #expect(bounds.1 != nil)
    // A clock anywhere a Date can be still yields a window.
    let early = UsageMapping.bounds(UsageMapping.Window(range: .week), now: .distantPast)
    #expect(early.0 != nil)
    let report = UsageReport(dailyCosts: [], sessions: [])
    let inverted = UsageMapping.Window(range: .custom, start: now, end: .distantPast)
    #expect(usage(report, window: inverted).sessions.isEmpty)
  }

  @Test(
    "A PR's check time may be any number",
    arguments: [
      Double.nan, .infinity, -.infinity, 1e300, -1e300, 0, -1,
    ])
  func prCheckTimes(checkedAt: Double) {
    let pullRequest = SessionPullRequest(
      url: "", host: "", repository: "", number: .max, title: nil, relationship: "exploded",
      providerName: nil, status: .unknown, stateCheckedAt: checkedAt)
    let row = PullRequestAdapter.summary(pullRequest, now: now)
    #expect(row.number == .max)
    #expect(row.title == "Pull request #\(UInt64.max)")
    #expect(row.status == .unknown)
  }

  @Test("Canvas cards hold any position and read a session's state")
  func canvasCards() throws {
    let list = SessionListStore()
    let card = CanvasMapping.card(
      Fixtures.summary("s", workspace: " \n "),
      position: CanvasPosition(x: .min, y: .max), list: list)
    #expect(card.left == .min)
    #expect(card.top == .max)
    #expect(card.workspace == "No working directory")

    func state(_ summary: OmnigentCoreFFI.SessionSummary) -> CanvasCard.State {
      CanvasMapping.cardState(summary, list: list)
    }
    #expect(state(Fixtures.summary("s", status: .needsResponse)) == .needsYou)
    #expect(state(Fixtures.summary("s", status: .running)) == .running)
    #expect(state(Fixtures.summary("s", failureMessage: "")) == .failed)
    #expect(state(Fixtures.summary("s")) == .idle)
    list.unreadIDs = ["s"]
    #expect(state(Fixtures.summary("s")) == .unread)
  }

  @Test("An empty canvas shows Main alone, loading until it reads")
  func emptyCanvas() async throws {
    let connection = try await Fixtures.connection()
    let canvas = try #require(connection.canvas)
    let view = CanvasMapping.state(canvas, list: connection.sessionList)
    #expect(view.boards.map(\.name) == ["Main"])
    #expect(view.activeBoard == CanvasMapping.mainBoardID)
    #expect(view.cards.isEmpty)
    #expect(view.isLoading)
    await canvas.load(viewerID: nil)
    let loaded = CanvasMapping.state(canvas, list: connection.sessionList)
    #expect(!loaded.isLoading)
  }

  @Test("A folder listing stops at its page limit when the cursor never runs out")
  func endlessListing() async throws {
    let source = EndlessDirectory()
    let listing = try await MarkdownLinksAdapter.listing(of: "src", source: source)
    #expect(source.reads == MarkdownLinksAdapter.maxListingPages)
    #expect(listing.files == ["file"])
    #expect(listing.folders == ["folder"])
  }

  @Test("A row's time may be either end of the 64-bit range")
  func rowTimes() {
    for createdAt in [Int64.min, .max] {
      var row = Fixtures.userRow("r", text: "")
      row.createdAt = createdAt
      #expect(
        OmnigentUIComponents.Row(row).createdAt
          == Date(timeIntervalSince1970: TimeInterval(createdAt)))
    }
    #expect(OmnigentUIComponents.Row(Fixtures.userRow("r", text: "")).createdAt == nil)
  }
}
