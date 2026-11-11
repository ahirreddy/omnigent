import Foundation
import Observation
import OmnigentCoreFFI
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentStores

/// A sidebar edit shows before the server answers, and a refused one is taken back.
@MainActor
@Suite("Sidebar edits before the server answers", .timeLimit(.minutes(1)))
struct SessionListIntentTests {
  private static let ids = ["conv_a", "conv_b", "conv_c"]

  private static func row(_ id: String, _ fields: String = "") -> String {
    #"{"id":"\#(id)","title":"Title of \#(id)","status":"idle","created_at":1,"# + fields
      + #""permission_level":4}"#
  }

  /// A connection whose list has three sessions the caller owns. The list hears of changes
  /// only while its connection lives, so the caller keeps this.
  private func connected(_ server: RouteServer) async throws -> ConnectionStore {
    let rows = Self.ids.map { Self.row($0) }.joined(separator: ",")
    server.route("/v1/sessions", .json(#"{"object":"list","data":[\#(rows)],"has_more":false}"#))
    for id in Self.ids { server.route("/v1/sessions/\(id)", method: "GET", .json(Self.row(id))) }
    let store = try await connectedStore(server)
    let list = store.sessionList
    try await eventually("the list") { list.isLoaded && list.visible.count == Self.ids.count }
    return store
  }

  @Test("A rename shows while the server holds it, and only its own row's readers hear of it")
  func heldRename() async throws {
    let server = RouteServer()
    let gate = server.hold("/v1/sessions/conv_a", method: "PATCH")
    server.route(
      "/v1/sessions/conv_a", method: "PATCH", .json(Self.row("conv_a", #""title":"Renamed","#)))
    let store = try await connected(server)
    let list = store.sessionList
    let otherHeard = Mutex(false)
    withObservationTracking {
      _ = (list.session("conv_b"), list.attention(of: "conv_b"))
    } onChange: {
      otherHeard.withLock { $0 = true }
    }
    let ownHeard = Mutex(false)
    withObservationTracking {
      _ = list.session("conv_a")
    } onChange: {
      ownHeard.withLock { $0 = true }
    }

    let renaming = Task { await list.rename("conv_a", to: "Renamed") }
    try await eventually("the new title") { list.session("conv_a")?.title == "Renamed" }
    try await eventually("the write") { gate.arrivals == 1 }
    #expect(list.editError == nil)
    gate.release()
    #expect(await renaming.value)
    #expect(list.session("conv_a")?.title == "Renamed")
    #expect(ownHeard.withLock { $0 })
    #expect(!otherHeard.withLock { $0 }, "a reader of another session is not notified")
  }

  @Test("A refused rename puts the old title back and offers the rename again")
  func refusedRename() async throws {
    let server = RouteServer()
    let gate = server.hold("/v1/sessions/conv_a", method: "PATCH")
    server.fail("/v1/sessions/conv_a", method: "PATCH", status: 409, detail: "Not yours")
    let store = try await connected(server)
    let list = store.sessionList
    let retries = Mutex(0)
    list.offerRetry("Nothing failed yet") { retries.withLock { $0 += 1 } }
    #expect(list.editRetry == nil, "no failure to offer it beside")

    let renaming = Task { await list.rename("conv_a", to: "Renamed") }
    try await eventually("the new title") { list.session("conv_a")?.title == "Renamed" }
    gate.release()
    #expect(await !renaming.value)
    try await eventually("the old title") { list.session("conv_a")?.title == "Title of conv_a" }
    #expect(list.editError?.message.contains("Not yours") == true)

    list.offerRetry("Could Not Rename the Session") { retries.withLock { $0 += 1 } }
    #expect(list.editRetry?.title == "Could Not Rename the Session")
    list.editRetry?.run()
    #expect(retries.withLock { $0 } == 1)
    list.dismissEditError()
    #expect(list.editRetry == nil, "the offer goes with the failure")
  }

  @Test("Archiving several sends every write at once and reports the ones refused")
  func batchArchive() async throws {
    let server = RouteServer()
    let gates = Self.ids.map { server.hold("/v1/sessions/\($0)", method: "PATCH") }
    server.route(
      "/v1/sessions/conv_a", method: "PATCH", .json(Self.row("conv_a", #""archived":true,"#)))
    server.fail("/v1/sessions/conv_b", method: "PATCH", status: 409, detail: "Not yours")
    server.route(
      "/v1/sessions/conv_c", method: "PATCH", .json(Self.row("conv_c", #""archived":true,"#)))
    let store = try await connected(server)
    let list = store.sessionList

    let archiving = Task { await list.setArchived(Self.ids, true) }
    try await eventually("the rows to leave") { list.visible.isEmpty }
    #expect(list.departing == Set(Self.ids))
    try await eventually("every write, none waiting for another") {
      gates.allSatisfy { $0.arrivals == 1 }
    }
    for gate in gates { gate.release() }
    #expect(await archiving.value == ["conv_b"])
    #expect(list.departing.isEmpty)
    #expect(list.editError?.message.contains("Not yours") == true)
    try await eventually("the refused row") { list.visible.map(\.id) == ["conv_b"] }

    server.route(
      "/v1/sessions/conv_a", method: "PATCH", .json(Self.row("conv_a", #""archived":false,"#)))
    #expect(await list.setArchived("conv_a", false))
    #expect(list.departing.isEmpty, "a restored session is not on its way out")
    #expect(list.editError == nil, "the next success clears the failure")
    try await eventually("the restored row") { list.visible.map(\.id).contains("conv_a") }
  }

  @Test("A delete hides its row while the server holds it, and a refusal brings the row back")
  func refusedDelete() async throws {
    let server = RouteServer()
    let gate = server.hold("/v1/sessions/conv_a", method: "DELETE")
    server.fail("/v1/sessions/conv_a", method: "DELETE", status: 409, detail: "Still running")
    let store = try await connected(server)
    let list = store.sessionList

    let deleting = Task { await list.delete("conv_a") }
    try await eventually("the row to leave") { list.session("conv_a") == nil }
    #expect(list.departing == ["conv_a"])
    try await eventually("the write") { gate.arrivals == 1 }
    gate.release()
    #expect(await !deleting.value)
    #expect(list.departing.isEmpty)
    try await eventually("the row again") { list.session("conv_a") != nil }
    #expect(list.editError?.message.contains("Still running") == true)
  }

  @Test("An answer waits for the events the core sent before it")
  func eventsBeforeAnAnswer() async throws {
    let store = try disconnectedStore(RouteServer())
    await store.eventsSentSoFarApplied()
    #expect(store.eventsApplied == 0, "nothing was sent, so there is nothing to wait for")

    store.relay.onEvent(event: .sessionListLoaded)
    #expect(!store.sessionList.isLoaded, "the event is still on its way")
    await store.eventsSentSoFarApplied()
    #expect(store.sessionList.isLoaded)
  }
}
