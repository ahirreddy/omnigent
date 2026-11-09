import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The sidebar's remaining actions, each as its control calls it.
@MainActor
@Suite("Sidebar wiring", .serialized, .timeLimit(.minutes(1)))
struct SidebarWiringTests {
  private func summary(_ session: ServerSession, _ id: String) throws
    -> OmnigentUIComponents.SessionSummary
  {
    OmnigentUIComponents.SessionSummary(try #require(session.connection.sessionList.session(id)))
  }

  @Test("Quick filters, Show and View Archived change which sessions the list holds")
  func filters() async throws {
    let session = try await signedInSession(threeSessionServer())
    let view = connectedView(session, WindowSelection())
    let actions = view.sidebarActions
    let list = session.connection.sessionList
    actions.viewArchived?()
    #expect(list.filter == .archived)
    #expect(view.sidebarModel.display.show == .archived)
    actions.setDisplay?(view.sidebarModel.display.with(show: .all))
    #expect(list.filter == .all)
    actions.setQuickFilter?(.running)
    #expect(list.filter == .running)
    actions.sessions.setFilter?(.needsResponse)
    #expect(list.filter == .needsResponse)
  }

  @Test("New Session and Retry in the list go where they say")
  func newSessionAndRetry() async throws {
    let server = threeSessionServer()
    let session = try await signedInSession(server)
    let selection = WindowSelection(.session("conv_a"))
    let actions = connectedView(session, selection).sidebarActions.sessions
    actions.newSession?()
    #expect(selection.page == .newSession)
    let reads = server.requests("GET", "/v1/sessions").count
    actions.retry?()
    try await eventually("another read") { server.requests("GET", "/v1/sessions").count > reads }
  }

  @Test("A row's Archive and Leave reach the server")
  func archiveAndLeave() async throws {
    let server = threeSessionServer()
    server.route("/v1/sessions/conv_b/collaborators/me", method: "DELETE", .json("{}"))
    let session = try await signedInSession(server)
    let view = connectedView(session, WindowSelection())
    let actions = view.sidebarActions.sessions
    actions.setArchived?(try summary(session, "conv_a"), true)
    try await eventually("the archive") {
      (try? server.patched("/v1/sessions/conv_a").last?["archived"] as? Bool) == true
    }
    actions.leave?(try summary(session, "conv_b"))
    try await eventually("the session to leave the list") {
      session.connection.sessionList.editError != nil
        || session.connection.sessionList.session("conv_b") == nil
    }
  }

  @Test("Dropping a row on Pinned pins it, and dropping it out unpins it")
  func droppingARow() async throws {
    let server = threeSessionServer()
    let session = try await signedInSession(server)
    let actions = connectedView(session, WindowSelection()).sidebarActions
    actions.dropSession?(try summary(session, "conv_a"), .pin(slotOf: nil))
    try await eventually("the pin") {
      (try? server.patched("/v1/sessions/conv_a").count) == 1
    }
    actions.dropSession?(try summary(session, "conv_a"), .unpin)
    try await eventually("the unpin") {
      (try? server.patched("/v1/sessions/conv_a").count) == 2
    }
  }

  @Test("Load More in the sidebar reads the next page")
  func loadingMore() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions", method: "GET",
      .json(
        #"{"object":"list","data":[\#(sessionRow("conv_a", host: "mac", workspace: "/w", updatedAt: 3))],"has_more":true,"last_id":"conv_a"}"#
      ))
    let session = try await signedInSession(server)
    let actions = connectedView(session, WindowSelection()).sidebarActions
    let reads = server.requests("GET", "/v1/sessions").count
    actions.loadMoreSessions?()
    try await eventually("the next page") { server.requests("GET", "/v1/sessions").count > reads }
  }
}
