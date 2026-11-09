import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// What one account's data does when the sign-in ends.
@MainActor
@Suite("Ending a sign-in", .timeLimit(.minutes(1)))
struct SignOutTests {
  private let address = "http://127.0.0.1:6767"

  private func serverWithSession() -> RouteServer {
    let server = RouteServer()
    server.route(
      "/v1/sessions",
      .json(
        #"{"object":"list","has_more":false,"data":[{"id":"conv_a","title":"Private","status":"idle","created_at":1,"updated_at":2}]}"#
      ))
    return server
  }

  /// An accounts server the user can sign in to with a password.
  private func accountsServer() -> RouteServer {
    let server = serverWithSession()
    server.route(
      "/.well-known/omnigent.json", .json(#"{"manifest_version":1,"auth":{"mode":"accounts"}}"#))
    server.route(
      "/v1/info", .json(#"{"single_user":false,"accounts_enabled":true,"needs_setup":false}"#))
    server.route(
      "/auth/login",
      .json(#"{"token":"tok","expires_in":3600,"user":{"id":"local"}}"#))
    return server
  }

  private func server(user: String) -> ConnectedServer {
    ConnectedServer(
      baseUrl: address, serverName: nil, userId: user, accountId: user, mode: .accounts)
  }

  private func listed(_ store: ConnectionStore) async throws {
    try await eventually("the list") { store.sessionList.session("conv_a") != nil }
  }

  private func expectNoRowsLeft(_ store: ConnectionStore) {
    let list = store.sessionList
    #expect(list.visible.isEmpty)
    #expect(list.sessionsByID.isEmpty)
    #expect(list.needsResponse.isEmpty)
    #expect(!list.isLoaded)
    #expect(list.viewerID == nil)
    #expect(list.unreadIDs.isEmpty)
    #expect(list.draftSessionIDs.isEmpty)
  }

  @Test("Signing out takes the account's sessions and open conversations away")
  func signOutForgetsTheAccount() async throws {
    let store = try disconnectedStore(accountsServer())
    await store.connect(serverURL: address)
    #expect(await store.signIn(username: "bob", password: "pw") != nil)
    try await listed(store)
    #expect(store.conversation("conv_a") != nil)
    #expect(store.workspace("conv_a") != nil)
    #expect(store.terminals("conv_a") != nil)
    let form = try #require(store.creation())
    form.stageAttachment(PendingAttachment(filename: "a", mediaType: nil, data: Data()))
    store.apply(.unreadChanged(sessionIds: ["conv_a"]))
    store.sessionList.setDraft("conv_a", true)

    await store.signOut()
    try await eventually("the sign-out") {
      if case .signInRequired = store.phase { return true }
      return false
    }
    expectNoRowsLeft(store)
    #expect(store.conversations.isEmpty)
    #expect(store.workspaceStores.isEmpty)
    #expect(store.terminalStores.isEmpty)
    #expect(store.creation()?.attachments.isEmpty == true, "the form starts over")
  }

  @Test("Disconnecting takes the rows off the screen and keeps open sessions for the next connect")
  func disconnectKeepsOpenSessions() async throws {
    let server = serverWithSession()
    let streams = FakeEventStreamTransport()
    let store = try await connectedStore(server, streams: streams)
    try await listed(store)
    let conversation = try #require(store.conversation("conv_a"))
    _ = await streams.waitForOpenedStream()

    store.disconnect()
    try await eventually("the disconnect") { store.phase == .disconnected }
    expectNoRowsLeft(store)
    #expect(store.conversation("conv_a") === conversation)

    await store.connect(serverURL: address)
    try await listed(store)
    #expect(store.sessionList.viewerID == "local")
    #expect(store.conversation("conv_a") === conversation)
    try await eventually("the stream to reopen") { streams.openedStreams.count == 2 }
  }

  @Test("A different account signing in never sees the last account's rows")
  func anotherAccount() async throws {
    let store = try await connectedStore(serverWithSession())
    try await listed(store)
    #expect(store.conversation("conv_a") != nil)
    store.apply(.connectionChanged(phase: .connected(server: server(user: "someone-else"))))
    #expect(store.sessionList.session("conv_a") == nil)
    #expect(store.conversations.isEmpty)
    #expect(store.sessionList.viewerID == "someone-else")
  }

  @Test("After a disconnect a different account still doesn't inherit open conversations")
  func anotherAccountAfterDisconnect() async throws {
    let store = try await connectedStore(serverWithSession())
    try await listed(store)
    #expect(store.conversation("conv_a") != nil)
    store.disconnect()
    try await eventually("the disconnect") { store.phase == .disconnected }
    store.apply(.connectionChanged(phase: .connected(server: server(user: "someone-else"))))
    #expect(store.conversations.isEmpty)
  }

  @Test("The same account connecting again keeps its rows and open conversations on screen")
  func sameAccount() async throws {
    let store = try await connectedStore(serverWithSession())
    try await listed(store)
    let conversation = try #require(store.conversation("conv_a"))
    store.apply(.connectionChanged(phase: .connecting(baseUrl: address)))
    store.apply(.connectionChanged(phase: .connected(server: server(user: "local"))))
    #expect(store.sessionList.session("conv_a") != nil)
    #expect(store.conversation("conv_a") === conversation)
  }

  @Test("The server ending the sign-in asks for it again and says why")
  func expiredOnARead() async throws {
    let server = accountsServer()
    let store = try disconnectedStore(server)
    await store.connect(serverURL: address)
    #expect(await store.signIn(username: "bob", password: "pw") != nil)
    try await listed(store)

    server.route("/v1/sessions", .json(#"{"detail":"expired"}"#, status: 401))
    store.refreshSessions()
    try await eventually("the sign-in request") {
      if case .signInRequired = store.phase { return true }
      return false
    }
    guard case .signInRequired(_, _, _, _, let reason) = store.phase else { return }
    #expect(reason?.requiresSignIn == true, "\(String(describing: reason))")
    #expect(store.sessionList.session("conv_a") != nil, "the same user may sign straight back in")
  }

  @Test("Signing back in after expiry reopens the conversation left open")
  func expiredThenBack() async throws {
    let server = accountsServer()
    let streams = FakeEventStreamTransport()
    let store = try disconnectedStore(server, streams: streams)
    await store.connect(serverURL: address)
    #expect(await store.signIn(username: "bob", password: "pw") != nil)
    try await listed(store)
    let conversation = try #require(store.conversation("conv_a"))
    _ = await streams.waitForOpenedStream()

    server.route("/v1/sessions", .json(#"{"detail":"expired"}"#, status: 401))
    store.refreshSessions()
    try await eventually("the sign-in request") {
      if case .signInRequired = store.phase { return true }
      return false
    }

    server.route(
      "/v1/sessions", .json(#"{"object":"list","has_more":false,"data":[]}"#))
    #expect(await store.signIn(username: "bob", password: "pw") != nil)
    try await eventually("the signed-in phase") { store.isSignedIn }
    #expect(store.conversation("conv_a") === conversation)
    try await eventually("the stream to reopen") { streams.openedStreams.count == 2 }
  }
}
