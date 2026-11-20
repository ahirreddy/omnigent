import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// The "New nested agent" row an open composer adds to the sidebar: where it sits, what
/// replaces it, and when it goes.
@MainActor
@Suite("Add nested agent: provisional sidebar row", .serialized, .timeLimit(.minutes(1)))
struct NestedAgentDraftRowTests {
  /// The sidebar's state over `server`'s list, with a draft beside `conv_src` under `token`.
  private func sidebar(
    _ server: AppServer, token: String = "tok", created: String? = nil
  ) async throws -> (SidebarViewState, ServerSession) {
    let session = try await signedInSession(server)
    let creation = try #require(session.connection.creation())
    let source = try await creation.nestedSource("conv_src").get()
    creation.openNestedDraft(key: "draft", source: source, token: token)
    if let created { creation.nestedDraftCreated(key: "draft", sessionID: created) }
    let view = connectedView(session, WindowSelection())
    return (view.sidebarState, session)
  }

  @Test("A standalone source gets a family of its own, and the row is its last member")
  func standaloneSource() async throws {
    let (state, _) = try await sidebar(nestedServer())
    let ids = state.list.sessions.map(\.id)
    let source = try #require(ids.firstIndex(of: "conv_src"))
    #expect(ids.dropFirst(source + 1).first == "draft", "right after its source")
    let row = try #require(state.list.sessions.first { $0.id == "draft" })
    #expect(row.title == "New nested agent")
    #expect(
      row.family
        == SessionFamilyInfo(
          id: "conv_src", representativeID: "conv_src",
          representativeTitle: "Coordinator"))
    #expect(state.list.sessions[source].family?.representativeID == "conv_src")
    #expect(row.nestedUnder == "conv_src")
    #expect(!row.canPin && !row.canArchive && !row.canRename)
    #expect(state.nestedDrafts == ["draft": "conv_src"])
    #expect(state.destination(of: row) == .nestedSession(sourceID: "conv_src"))
    #expect((state.rowInfo["draft"]?.createdAt ?? 0) >= 5, "newer than its family")
  }

  @Test("A member's row joins its family and its project folder")
  func memberInAProject() async throws {
    let server = nestedServer()
    let member =
      #"{"id":"conv_src","status":"idle","created_at":1,"updated_at":5,"title":"Coordinator","host_id":"mac","workspace":"/work/app","permission_level":4,"archived":false,"project_id":"p1","family":{"id":"lead","representative_id":"lead","representative_title":"Lead"}}"#
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(member)],"has_more":false}"#))
    server.route("/v1/sessions/conv_src", .json(member))
    server.route("/v1/sessions/projects", .json(#"[{"id":"p1","name":"Alpha"}]"#))
    let session = try await signedInSession(server)
    await session.connection.sessionList.loadProjects()
    let creation = try #require(session.connection.creation())
    creation.openNestedDraft(
      key: "draft", source: try await creation.nestedSource("conv_src").get(), token: "tok")
    let state = connectedView(session, WindowSelection()).sidebarState
    let row = try #require(state.list.sessions.first { $0.id == "draft" })
    #expect(row.family?.id == "lead")
    #expect(row.nestedUnder == "lead")
    let folder = try #require(state.projects.first { $0.sessionIds.contains("conv_src") })
    #expect(folder.sessionIds.last == "draft")
  }

  @Test("A row carrying the create's token, or the created session, takes its place")
  func replaced() async throws {
    let server = nestedServer()
    let pushed =
      #"{"id":"conv_new","status":"idle","created_at":9,"updated_at":9,"permission_level":4,"labels":{"omnigent.client_create_token":"tok"}}"#
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(nestedSourceRow),\#(pushed)],"has_more":false}"#))
    let (byToken, _) = try await sidebar(server)
    #expect(!byToken.list.sessions.contains { $0.title == "New nested agent" })
    #expect(byToken.nestedDrafts.isEmpty)

    let (created, _) = try await sidebar(nestedServer(), created: "conv_new")
    let row = try #require(created.list.sessions.first { $0.title == "New nested agent" })
    #expect(row.id == "conv_new", "the row stands for the created session until it is listed")
    #expect(created.nestedDrafts.isEmpty)
    #expect(created.destination(of: row) == .session("conv_new"))
  }

  @Test("No row shows where the sidebar doesn't show its source")
  func sourceNotShown() async throws {
    let server = nestedServer()
    let (state, session) = try await sidebar(server)
    let elsewhere = SidebarViewState(list: SessionListViewState(sessions: []))
    let applied = SidebarNestedDraftRows.applied(
      to: elsewhere, drafts: session.connection.creationStore?.nestedDrafts ?? [],
      list: session.connection.sessionList)
    #expect(applied.list.sessions.isEmpty)
    #expect(state.list.sessions.contains { $0.id == "draft" })
  }

  @Test("While the composer is open its row shows; the created session's row replaces it")
  func inTheWindow() async throws {
    let server = nestedServer()
    server.route(
      "/v1/sessions", method: "POST",
      .json(
        #"{"id":"conv_new","status":"idle","created_at":9,"agent_id":"ag_claude","host_id":"mac","permission_level":4,"title":"hello","family":{"id":"conv_src","representative_id":"conv_src","representative_title":"Coordinator"}}"#,
        status: 201))
    let session = try await signedInSession(server)
    let selection = WindowSelection(.nestedSession(sourceID: "conv_src"))
    let view = ConnectedServerView(
      session: session, selection: selection.binding, sidebar: SidebarModel(),
      opener: ExternalURLOpener { _ in true }, openInNewWindow: nil, serverSwitching: nil)
    let screen = OffscreenWindow(view, width: 1200, height: 800)
    defer { screen.close() }
    try await settle(screen, untilShowing: "A new conversation alongside Coordinator")
    try await settle(screen, untilShowing: "New nested agent")
    let creation = try #require(session.connection.creationStore)
    #expect(creation.nestedDrafts.count == 1)
    let field = try #require(screen.allViews.first { $0 is NSTextView })
    try screen.click(field)
    try screen.type("hello")
    try screen.press(keyCode: 36, characters: "\r")
    try await settle(screen, until: "the new session") { selection.page == .session("conv_new") }
    try await settle(screen, until: "the row to retire") { creation.nestedDrafts.isEmpty }
    #expect(try !screen.shows("New nested agent"))
  }

  @Test("Leaving keeps the draft's row: it reopens the composer as left, and Delete Draft ends it")
  func leavingKeepsTheDraft() async throws {
    let session = try await signedInSession(nestedServer())
    let selection = WindowSelection(.nestedSession(sourceID: "conv_src"))
    let view = ConnectedServerView(
      session: session, selection: selection.binding, sidebar: SidebarModel(),
      opener: ExternalURLOpener { _ in true }, openInNewWindow: nil, serverSwitching: nil)
    let screen = OffscreenWindow(view, width: 1200, height: 800)
    defer { screen.close() }
    try await settle(screen, untilShowing: "New nested agent")
    let creation = try #require(session.connection.creationStore)
    let row = try #require(creation.nestedDrafts.first)
    let field = try #require(screen.allViews.first { $0 is NSTextView })
    try screen.click(field)
    try screen.type("draft words")
    try await settle(screen, until: "the draft kept") {
      creation.composerDrafts["conv_src"] == "draft words"
    }
    session.nestedComposerDrafts.form(for: "conv_src").name = "Kept name"
    selection.page = .newSession
    try await settle(screen, untilShowing: NewSessionPage.defaultHeading)
    #expect(creation.nestedDrafts.map(\.key) == [row.key], "the row stays")
    #expect(try screen.shows("New nested agent"))

    selection.page = .nestedSession(sourceID: "conv_src")
    try await settle(screen, untilShowing: "A new conversation alongside Coordinator")
    try await settle(screen, until: "the text back") {
      screen.allViews.contains { ($0 as? NSTextView)?.string == "draft words" }
    }
    #expect(session.nestedComposerDrafts.form(for: "conv_src").name == "Kept name")
    #expect(creation.nestedDrafts.map(\.key) == [row.key], "the same row")

    view.deleteNestedDraft(rowID: row.id)
    #expect(creation.nestedDrafts.isEmpty)
    #expect(creation.composerDrafts["conv_src"] == nil)
    #expect(selection.page == .session("conv_src"), "the source shows in the composer's place")
    #expect(session.nestedComposerDrafts.form(for: "conv_src").name.isEmpty, "a fresh composer")
  }

  @Test("A nested composer keeps its files apart from the other composers' while it is away")
  func keptFiles() async throws {
    let connection = try await signedInStore(nestedServer())
    let creation = try #require(connection.creation())
    let drafts = NestedComposerDrafts()
    _ = drafts.form(for: "conv_src")
    let page = PendingAttachment(filename: "page.txt", mediaType: "text/plain", data: Data())
    let nested = PendingAttachment(filename: "nested.txt", mediaType: "text/plain", data: Data())
    creation.stageAttachment(page)
    drafts.arrive("conv_src", creation: creation)
    #expect(creation.attachments.isEmpty, "the new session's file waits")
    creation.stageAttachment(nested)
    drafts.leave("conv_src", creation: creation)
    #expect(creation.attachments.map(\.filename) == ["page.txt"])
    drafts.arrive("conv_src", creation: creation)
    #expect(creation.attachments.map(\.filename) == ["nested.txt"])
    drafts.leave("conv_src", creation: creation)
    drafts.discard("conv_src")
    drafts.arrive("conv_src", creation: creation)
    #expect(creation.attachments.isEmpty, "a deleted draft's files go with it")
  }
}
