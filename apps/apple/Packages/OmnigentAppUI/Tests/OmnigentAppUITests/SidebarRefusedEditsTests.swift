import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import Testing

@testable import OmnigentAppUI

/// `id`'s row as the server answers an archive of it.
nonisolated func archivedRow(_ id: String) -> HttpResponse {
  .json(sessionRow(id, host: "mac", workspace: "/work/\(id)", updatedAt: 30, archived: true))
}

/// A pin or an archive the server refuses: what was shown at the click is taken back.
@MainActor
@Suite("Sidebar edits the server refuses", .serialized, .timeLimit(.minutes(1)))
struct SidebarRefusedEditsTests {
  @Test("An archive the server refuses keeps the tabs, returns to the session and offers Retry")
  func aRefusedArchiveKeepsTabs() async throws {
    let server = threeSessionServer()
    let gate = server.hold("/v1/sessions/conv_a", method: "PATCH")
    server.route("/v1/sessions/conv_a", method: "PATCH", .json(#"{"detail":"nope"}"#, status: 422))
    let session = try await signedInSession(server)
    let list = session.connection.sessionList
    let view = connectedView(session, WindowSelection())
    session.tabs.showChat("conv_b")
    session.tabs.showChat("conv_a")
    view.edit(.archive(["conv_a"], true))
    #expect(view.sidebarModel.undo != nil)
    try await eventually("the write") { gate.arrivals == 1 }
    #expect(session.tabs.page == .session("conv_b"), "the window left before the answer")
    #expect(!list.visible.contains { $0.id == "conv_a" }, "and so did the row")
    gate.release()
    try await eventually("the offer to retry") { list.editRetry != nil }
    #expect(list.editRetry?.title == "Could Not Archive the Session")
    #expect(list.editError?.message.contains("nope") == true)
    #expect(session.tabs.groups["conv_a"] != nil, "the session wasn't archived")
    #expect(session.tabs.page == .session("conv_a"), "back on the session it left")
    #expect(view.sidebarModel.undo == nil, "nothing to undo")

    server.route("/v1/sessions/conv_a", method: "PATCH", archivedRow("conv_a"))
    list.editRetry?.run()
    try await eventually("the retried archive") { session.tabs.groups["conv_a"] == nil }
    #expect(list.editError == nil)
    #expect(view.sidebarModel.undo?.banner?.kind == .archived(count: 1))
  }

  @Test("A refused archive leaves the window where the user went meanwhile")
  func aRefusedArchiveAfterMovingOn() async throws {
    let server = threeSessionServer()
    let gate = server.hold("/v1/sessions/conv_a", method: "PATCH")
    server.route("/v1/sessions/conv_a", method: "PATCH", .json(#"{"detail":"nope"}"#, status: 422))
    let session = try await signedInSession(server)
    let list = session.connection.sessionList
    let view = connectedView(session, WindowSelection())
    session.tabs.showChat("conv_a")
    view.edit(.archive(["conv_a"], true))
    try await eventually("the write") { gate.arrivals == 1 }
    #expect(session.tabs.page == nil, "no other session was open to show")
    session.tabs.showChat("conv_c")
    gate.release()
    try await eventually("the offer to retry") { list.editRetry != nil }
    #expect(session.tabs.page == .session("conv_c"))
    #expect(session.tabs.groups["conv_a"] != nil)
  }

  @Test("Archiving several tries every one: only those the server refused keep their tabs")
  func aPartlyRefusedArchive() async throws {
    let server = threeSessionServer()
    server.route("/v1/sessions/conv_a", method: "PATCH", archivedRow("conv_a"))
    server.route("/v1/sessions/conv_b", method: "PATCH", .json(#"{"detail":"nope"}"#, status: 422))
    server.route("/v1/sessions/conv_c", method: "PATCH", archivedRow("conv_c"))
    let session = try await signedInSession(server)
    let list = session.connection.sessionList
    let view = connectedView(session, WindowSelection())
    for id in ["conv_a", "conv_b", "conv_c"] { session.tabs.showChat(id) }
    view.edit(.archive(["conv_a", "conv_b", "conv_c"], true))
    #expect(view.sidebarModel.undo?.banner?.kind == .archived(count: 3))
    try await eventually("the offer to retry") { list.editRetry != nil }
    #expect(list.editRetry?.title == "Could Not Archive the Session")
    #expect(session.tabs.groups["conv_a"] == nil)
    #expect(session.tabs.groups["conv_b"] != nil)
    #expect(session.tabs.groups["conv_c"] == nil, "a refusal doesn't stop the others")
    #expect(view.sidebarModel.undo == nil, "an Undo of three would restore two it never offered")

    server.route("/v1/sessions/conv_b", method: "PATCH", archivedRow("conv_b"))
    list.editRetry?.run()
    try await eventually("the retried archive") { session.tabs.groups["conv_b"] == nil }
    #expect(try server.patched("/v1/sessions/conv_a").count == 1, "only the refused one is retried")
    #expect(try server.patched("/v1/sessions/conv_b").count == 2)
    #expect(view.sidebarModel.undo?.banner?.kind == .archived(count: 1))
  }

  @Test("A refused pin withdraws its Undo and offers the pin again")
  func aRefusedPin() async throws {
    let server = threeSessionServer()
    server.route("/v1/sessions/conv_b", method: "PATCH", .json(#"{"detail":"nope"}"#, status: 422))
    let session = try await signedInSession(server)
    let list = session.connection.sessionList
    let view = connectedView(session, WindowSelection())
    view.edit(.pin("conv_b", true))
    #expect(view.sidebarModel.undo?.banner?.kind == .pinned)
    try await eventually("the offer to retry") { list.editRetry != nil }
    #expect(list.editRetry?.title == "Could Not Pin the Session")
    #expect(view.sidebarModel.undo == nil)
    list.editRetry?.run()
    try await eventually("the pin again") {
      (try? server.patched("/v1/sessions/conv_b").count) == 2
    }
  }

  @Test("A refusal leaves a later change's Undo alone")
  func aRefusalKeepsALaterUndo() async throws {
    let server = threeSessionServer()
    server.route("/v1/sessions/conv_b", method: "PATCH", .json(#"{"detail":"nope"}"#, status: 422))
    let session = try await signedInSession(server)
    let list = session.connection.sessionList
    let view = connectedView(session, WindowSelection())
    view.edit(.pin("conv_b", true))
    let later = SidebarUndo(change: .pin("conv_c", false))
    view.sidebarModel.undo = later
    try await eventually("the offer to retry") { list.editRetry != nil }
    #expect(view.sidebarModel.undo?.id == later.id)
  }

  @Test("A failure's title names the change and how many sessions it missed")
  func failureTitles() {
    typealias Change = SidebarUndo.Change
    #expect(Change.pin("a", false).failureTitle(refused: 1) == "Could Not Unpin the Session")
    #expect(
      Change.archive(["a", "b"], true).failureTitle(refused: 2) == "Could Not Archive 2 Sessions")
    #expect(
      Change.archive(["a"], false).failureTitle(refused: 1) == "Could Not Unarchive the Session")
    #expect(
      Change.archive(["a", "b"], false).failureTitle(refused: 2) == "Could Not Unarchive 2 Sessions"
    )
    guard case .archive(let ids, false) = Change.archive(["a", "b"], false).limited(to: ["b"])
    else {
      Issue.record("an archive stays an archive")
      return
    }
    #expect(ids == ["b"])
    #expect(ConnectedServerView.failureTitle(of: .none) == "Could Not Move the Session")
  }
}
