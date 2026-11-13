import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// Where each server's group sorts are kept, and what a relaunch reads back.
@MainActor
@Suite("Sidebar group sorts: kept per server")
struct SidebarGroupSortStoreTests {
  private let work = SessionGroup.project("work")

  private var saved: SessionGroupSorts {
    SessionGroupSorts(chosen: [work.key: .custom], customOrder: [work.key: ["b", "a"]])
  }

  @Test("Saved sorts come back for their account, and for no other")
  func roundTrip() throws {
    let defaults = try scratchDefaults()
    SidebarGroupSortDefaults.save(saved, account: "one", defaults)
    #expect(SidebarGroupSortDefaults.load(account: "one", defaults) == saved)
    #expect(SidebarGroupSortDefaults.load(account: "two", defaults) == SessionGroupSorts())

    SidebarGroupSortDefaults.save(SessionGroupSorts(), account: "one", defaults)
    let key = SidebarGroupSortDefaults.key(account: "one")
    #expect(defaults.data(forKey: key) == nil, "with nothing chosen nothing is kept")
  }

  @Test("Sorts that no longer decode fall back to the defaults, and a failed save keeps the last")
  func unreadableAndUnwritable() throws {
    struct Unencodable: Error {}
    let defaults = try scratchDefaults()
    let key = SidebarGroupSortDefaults.key(account: "one")
    defaults.set(Data("not json".utf8), forKey: key)
    #expect(SidebarGroupSortDefaults.load(account: "one", defaults) == SessionGroupSorts())
    #expect(defaults.data(forKey: key) == nil)

    SidebarGroupSortDefaults.save(saved, account: "one", defaults)
    let other = SessionGroupSorts(chosen: [work.key: .name])
    SidebarGroupSortDefaults.save(other, account: "one", defaults) { _ in throw Unencodable() }
    #expect(SidebarGroupSortDefaults.load(account: "one", defaults) == saved)
  }

  @Test("The store saves each change, tells its readers, and a relaunch reads it back")
  func store() throws {
    let defaults = try scratchDefaults()
    let store = SidebarGroupSortStore(defaults: defaults)
    store.update(nil) { $0.chosen[work.key] = .name }
    #expect(store.sorts(for: nil) == SessionGroupSorts(), "no server is connected")

    let reads = { _ = store.sorts(for: "one") }
    let reorders = { store.update("one") { $0.reorder(work, shown: ["b", "a"]) } }
    #expect(observationNotifies(reads, when: reorders))
    #expect(store.sorts(for: "one") == saved)
    #expect(!observationNotifies(reads, when: reorders), "the same order again changes nothing")
    #expect(store.sorts(for: "two") == SessionGroupSorts(), "another server keeps its own")

    let relaunched = SidebarGroupSortStore(defaults: defaults)
    #expect(relaunched.sorts(for: "one") == saved)
  }
}

/// The sidebar's group sorts through the connected window's actions.
@MainActor
@Suite("Sidebar group sorts: the connected window", .serialized, .timeLimit(.minutes(1)))
struct SidebarGroupSortWiringTests {
  private let alpha = SessionGroup.project("p1")

  private func row(_ id: String, updatedAt: Int, extra: String) -> String {
    #"{"id":"\#(id)","status":"idle","created_at":1,"updated_at":\#(updatedAt),"host_id":"mac","workspace":"/w","permission_level":4,"archived":false\#(extra)}"#
  }

  private func pin(_ id: String, updatedAt: Int, stamp: String) -> String {
    row(id, updatedAt: updatedAt, extra: #","labels":{"omnigent.pinned":"\#(stamp)"}"#)
  }

  private func serve(_ rows: [String], on server: AppServer) {
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(rows.joined(separator: ","))],"has_more":false}"#))
  }

  /// `conv_a` then `conv_b` in pin order, `conv_b` the more recent.
  private func pinnedServer() -> AppServer {
    let server = newSessionServer()
    let pins = [pin("conv_a", updatedAt: 5, stamp: "1"), pin("conv_b", updatedAt: 9, stamp: "2")]
    serve(pins, on: server)
    server.route("/v1/sessions/conv_a", .json(pins[0]))
    server.route("/v1/sessions/conv_b", .json(pins[1]))
    return server
  }

  /// `conv_a` and `conv_b` filed in the project Alpha, `conv_c` loose.
  private func projectServer() -> AppServer {
    let server = newSessionServer()
    let filed = #","project_id":"p1""#
    serve(
      [
        row("conv_a", updatedAt: 30, extra: filed), row("conv_b", updatedAt: 29, extra: filed),
        row("conv_c", updatedAt: 28, extra: ""),
      ], on: server)
    server.route("/v1/sessions/projects", .json(#"[{"id":"p1","name":"Alpha"}]"#))
    server.route(
      "/v1/projects/order", method: "GET",
      .json(#"{"sort_mode":"manual","ordered_project_ids":["p1"]}"#))
    return server
  }

  private func window(
    _ session: ServerSession, _ selection: WindowSelection, store: SidebarGroupSortStore
  ) -> ConnectedServerView {
    ConnectedServerView(
      session: session, selection: selection.binding, sidebar: SidebarModel(groupSorts: store),
      opener: ExternalURLOpener { _ in true }, openInNewWindow: nil, serverSwitching: nil)
  }

  private func order(_ group: SessionGroup, _ view: ConnectedServerView) -> [String] {
    SidebarNavigationOrder.groupIDs(group, in: view.sidebarState)
  }

  @Test("A chosen sort orders its group, the pinned shortcuts follow it, and a relaunch keeps it")
  func choosingASort() async throws {
    let session = try await signedInSession(pinnedServer())
    let defaults = try scratchDefaults()
    let selection = WindowSelection()
    let view = window(session, selection, store: SidebarGroupSortStore(defaults: defaults))
    #expect(order(.pinned, view) == ["conv_a", "conv_b"], "the pin order")
    #expect(view.sidebarState.sort(of: .pinned) == .custom)

    view.sidebarActions.setGroupSort?(.pinned, .recent)
    #expect(order(.pinned, view) == ["conv_b", "conv_a"])
    view.openPinnedSession(0)
    #expect(selection.page == .session("conv_b"))

    let account = try #require(view.groupSortAccount)
    let kept = SidebarGroupSortDefaults.load(account: account, defaults)
    #expect(kept == SessionGroupSorts(chosen: [SessionGroup.pinned.key: .recent]))
    let relaunched = window(
      session, WindowSelection(), store: SidebarGroupSortStore(defaults: defaults))
    #expect(order(.pinned, relaunched) == ["conv_b", "conv_a"])
  }

  @Test("Reordering the pins saves the order on the server, and a refusal offers it again")
  func reorderingPins() async throws {
    let server = pinnedServer()
    server.route("/v1/sessions/conv_b", method: "PATCH", .json(#"{"detail":"nope"}"#, status: 422))
    let session = try await signedInSession(server)
    let list = session.connection.sessionList
    let defaults = try scratchDefaults()
    let view = window(session, WindowSelection(), store: SidebarGroupSortStore(defaults: defaults))
    view.sidebarActions.setGroupSort?(.pinned, .recent)

    view.sidebarActions.reorderGroup?(.pinned, ["conv_b", "conv_a"])
    #expect(view.sidebarState.sort(of: .pinned) == .custom, "a reorder switches to Custom")
    try await eventually("the offer to retry") { list.editRetry != nil }
    #expect(list.editRetry?.title == "Could Not Reorder the Pinned Sessions")
    #expect(order(.pinned, view) == ["conv_a", "conv_b"], "the refused order is taken back")

    server.route(
      "/v1/sessions/conv_b", method: "PATCH", .json(pin("conv_b", updatedAt: 9, stamp: "0")))
    list.editRetry?.run()
    try await eventually("the saved order") { order(.pinned, view) == ["conv_b", "conv_a"] }
    let edit = try #require(try server.patched("/v1/sessions/conv_b").last)
    #expect((edit["labels"] as? [String: String])?["omnigent.pinned"] == "0")
    let account = try #require(view.groupSortAccount)
    let kept = SidebarGroupSortDefaults.load(account: account, defaults)
    #expect(kept.customOrder.isEmpty, "the server keeps the pin order")
  }

  @Test("A project's custom order stays on this device, asks the server nothing, and is kept")
  func reorderingAProject() async throws {
    let server = projectServer()
    let session = try await signedInSession(server)
    let list = session.connection.sessionList
    try await eventually("the projects") { !list.projects.isEmpty }
    let defaults = try scratchDefaults()
    let view = window(session, WindowSelection(), store: SidebarGroupSortStore(defaults: defaults))
    #expect(order(alpha, view) == ["conv_a", "conv_b"], "most recent first")

    // Choosing Custom keeps the rows where they are, whatever happens to them next.
    view.sidebarActions.setGroupSort?(alpha, .custom)
    let account = try #require(view.groupSortAccount)
    #expect(
      SidebarGroupSortDefaults.load(account: account, defaults).customOrder
        == [alpha.key: ["conv_a", "conv_b"]])

    view.sidebarActions.reorderGroup?(alpha, ["conv_b", "conv_a"])
    #expect(order(alpha, view) == ["conv_b", "conv_a"])
    #expect(view.sidebarState.sort(of: .pinned) == .custom, "Pinned keeps its own sort")
    #expect(server.requests("PATCH", "/v1/sessions/conv_b").isEmpty)
    #expect(list.editError == nil)

    let relaunched = window(
      session, WindowSelection(), store: SidebarGroupSortStore(defaults: defaults))
    #expect(order(alpha, relaunched) == ["conv_b", "conv_a"])
  }

  @Test("A group sorted by name is drawn again for a rename that moves a row, and only then")
  func aRenameMovesARow() {
    let list = SidebarBenchmarks.list(8)
    let group = SessionGroup.project("p0")
    let sorts = SessionGroupSorts(chosen: [group.key: .name])
    let display = SessionDisplayOptions()
    let memo = SidebarStateMemo()
    let state = { memo.state(list: list, display: display, sorts: sorts, server: nil) }
    let reads = { _ = state() }
    reads()
    #expect(SidebarNavigationOrder.groupIDs(group, in: state()) == ["s0", "s6"])

    var renamed = SidebarBenchmarks.sessions(8)[0]
    renamed.title = "Zebra"
    #expect(observationNotifies(reads) { list.apply(.upsert(sessions: [renamed])) })
    #expect(SidebarNavigationOrder.groupIDs(group, in: state()) == ["s6", "s0"])
    #expect(
      state() == SidebarAdapter.state(list: list, display: display, sorts: sorts, server: nil))

    reads()
    renamed.title = "Zulu"
    #expect(!observationNotifies(reads) { list.apply(.upsert(sessions: [renamed])) })

    // In the list's own order a title moves no row.
    let plain = SidebarStateMemo()
    let plainReads = { _ = plain.state(list: list, display: display, server: nil) }
    plainReads()
    renamed.title = "Aardvark"
    #expect(!observationNotifies(plainReads) { list.apply(.upsert(sessions: [renamed])) })
  }

  @Test("The window forgets a deleted project's sort and the place of a session that left")
  func forgetting() async throws {
    let server = projectServer()
    let session = try await signedInSession(server)
    let list = session.connection.sessionList
    try await eventually("the projects") { !list.projects.isEmpty && list.projectSortMode != nil }
    let defaults = try scratchDefaults()
    let store = SidebarGroupSortStore(defaults: defaults)
    let account = try #require(session.connection.connectedServer?.accountId)
    let gone = SessionGroup.project("gone")
    store.update(account) {
      $0 = SessionGroupSorts(
        chosen: [alpha.key: .custom, gone.key: .name],
        customOrder: [alpha.key: ["left", "conv_b", "conv_a"], gone.key: ["conv_c"]])
    }
    // The open folder reads its page, after which every session of the project is known.
    let expandedKey = "omnigent:sidebar-expanded-projects"
    UserDefaults.standard.set("p1", forKey: expandedKey)
    defer { UserDefaults.standard.removeObject(forKey: expandedKey) }
    let view = window(session, WindowSelection(), store: store)
    let screen = OffscreenWindow(view, width: 1200, height: 800)
    defer { screen.close() }

    let expected = SessionGroupSorts(
      chosen: [alpha.key: .custom], customOrder: [alpha.key: ["conv_b", "conv_a"]])
    try await settle(screen, until: "the saved sorts to match the sidebar") {
      store.sorts(for: account) == expected
    }
    #expect(SidebarGroupSortDefaults.load(account: account, defaults) == expected)
    #expect(order(alpha, view) == ["conv_b", "conv_a"])
  }
}
