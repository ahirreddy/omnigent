import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// Where each event from the core lands, including events for sessions no longer open.
@MainActor
@Suite("Connection events", .timeLimit(.minutes(1)))
struct ConnectionStoreEventTests {
  private let expired = CoreError.Auth(
    kind: .credentialExpired, failure: .expired, message: "Sign in again", detail: nil)

  @Test("An expired sign-in leaves connected with the reason and clears a pending browser login")
  func authExpiry() async throws {
    let store = try await connectedStore(RouteServer())
    let login = BrowserLoginInfo(loginUrl: "https://x", userCode: "ABCD", expiresAtMs: 9)
    store.apply(.connectionChanged(phase: .awaitingBrowserLogin(baseUrl: "b", login: login)))
    #expect(store.browserLogin == login)
    #expect(!store.isSignedIn)

    store.apply(
      .connectionChanged(
        phase: .signInRequired(
          baseUrl: "b", serverName: nil, mode: .localSingleUser, methods: [], reason: expired)))
    #expect(store.browserLogin == nil)
    #expect(!store.isSignedIn)
    #expect(store.connectedServer == nil)
    #expect(expired.requiresSignIn)
  }

  @Test("A renewed credential counts up and keeps the new expiry, with no reconnect")
  func credentialRotation() async throws {
    let store = try await connectedStore(RouteServer())
    store.apply(.credentialRotated(expiresAtMs: 1234))
    store.apply(.credentialRotated(expiresAtMs: nil))
    #expect(store.credentialRotations == 2)
    #expect(store.credentialExpiresAtMs == nil)
    #expect(store.isSignedIn)
  }

  @Test("Events for a session that isn't open are dropped, not reopened")
  func closedSessionEvents() async throws {
    let store = try await connectedStore(RouteServer())
    let events: [CoreEvent] = [
      .sessionLinkChanged(sessionId: "gone", state: .live),
      .sessionHydrated(sessionId: "gone"),
      .historyPagingChanged(sessionId: "gone", hasOlder: true, isLoading: false),
      .transcriptReset(
        sessionId: "gone", revision: 1, rows: [], header: nil, sections: [], decisions: []),
      .transcriptChanged(
        sessionId: "gone", revision: 2,
        change: TranscriptChange(rows: [], header: nil, sections: nil)),
      .decisionsChanged(sessionId: "gone", decisions: []),
      .sessionFailure(sessionId: "gone", message: "x"),
      .sessionClosed(sessionId: "gone"),
      .sessionSuperseded(sessionId: "gone", targetSessionId: "other"),
    ]
    let before = store.eventsApplied
    for event in events { store.apply(event) }
    #expect(store.eventsApplied == before + events.count)
    #expect(store.conversations.isEmpty)
    #expect(store.issues.isEmpty)
  }

  @Test("Events for an open session reach its store")
  func openSessionEvents() async throws {
    let store = try await connectedStore(RouteServer())
    let conversation = try #require(store.conversation("conv_a"))
    store.apply(
      .transcriptReset(
        sessionId: "conv_a", revision: 7, rows: [transcriptRow("a")], header: sessionHeader(),
        sections: [], decisions: []))
    #expect(conversation.revision == 7)
    store.apply(
      .transcriptChanged(
        sessionId: "conv_a", revision: 8,
        change: TranscriptChange(
          rows: [.insert(index: 1, row: transcriptRow("b"))], header: nil, sections: nil)))
    #expect(conversation.rows.map(\.id) == ["a", "b"])
    store.apply(.sessionLinkChanged(sessionId: "conv_a", state: .connecting))
    #expect(conversation.link == .connecting)
    store.apply(.sessionHydrated(sessionId: "conv_a"))
    #expect(conversation.isHydrated)
    store.apply(.historyPagingChanged(sessionId: "conv_a", hasOlder: true, isLoading: false))
    #expect(conversation.hasOlderHistory)
    store.apply(.decisionsChanged(sessionId: "conv_a", decisions: []))
    store.apply(.sessionFailure(sessionId: "conv_a", message: "bad"))
    #expect(conversation.lastFailure == "bad")
    store.apply(.sessionSuperseded(sessionId: "conv_a", targetSessionId: "conv_b"))
    #expect(conversation.supersededBy == "conv_b")
    store.apply(.sessionClosed(sessionId: "conv_a"))
    #expect(conversation.isClosed)
  }

  @Test("A failure lands on its open session, else in the issues; a list failure tells the list")
  func errorRouting() async throws {
    let store = try await connectedStore(RouteServer())
    let conversation = try #require(store.conversation("conv_a"))
    let failure = CoreError.InvalidState(message: "x")
    store.apply(.error(scope: .session(sessionId: "conv_a"), error: failure))
    #expect(conversation.errors == [failure])
    #expect(store.issues.isEmpty)

    store.apply(.error(scope: .session(sessionId: "closed"), error: failure))
    #expect(store.issues.last?.scope == .session(sessionId: "closed"))

    store.apply(.error(scope: .sessionList, error: failure))
    #expect(store.issues.last?.scope == .sessionList)
    #expect(store.sessionList.lastError == failure)
  }

  @Test("Frame types this client doesn't know keep the newest twenty")
  func unknownFrames() async throws {
    let store = try await connectedStore(RouteServer())
    for index in 0..<25 { store.apply(.unknownUpdate(frameType: "frame\(index)")) }
    #expect(store.unknownUpdates.count == 20)
    #expect(store.unknownUpdates.first == "frame5")
  }

  @Test("Host and project changes bump their revisions and read the lists again")
  func serverLists() async throws {
    let server = RouteServer()
    let store = try await connectedStore(server)
    try await eventually("the first read") { !server.requests(to: "/v1/hosts").isEmpty }
    let hostReads = server.requests(to: "/v1/hosts").count
    store.apply(.hostsChanged)
    #expect(store.hostsRevision == 1)
    try await eventually("the hosts to reload") {
      server.requests(to: "/v1/hosts").count > hostReads
    }
    let projectReads = server.requests(to: "/v1/sessions/projects").count
    store.apply(.projectsChanged)
    #expect(store.projectsRevision == 1)
    try await eventually("the projects to reload") {
      server.requests(to: "/v1/sessions/projects").count > projectReads
    }
  }

  @Test("Hosts changing while signed out reads nothing")
  func hostsWhileSignedOut() throws {
    let server = RouteServer()
    let store = try disconnectedStore(server)
    store.apply(.hostsChanged)
    #expect(store.hostsRevision == 1)
    #expect(server.requests(to: "/v1/hosts").isEmpty)
  }

  @Test("Unread, badge, paging and link states reach their stores")
  func listState() async throws {
    let store = try await connectedStore(RouteServer())
    store.apply(.unreadChanged(sessionIds: ["a", "a", "b"]))
    #expect(store.sessionList.unreadIDs == ["a", "b"])
    store.apply(.badgeChanged(sessionIds: ["a"]))
    store.apply(.sessionListPagingChanged(hasMore: true, isLoading: true))
    #expect(store.sessionList.paging.hasMore)
    store.apply(.updatesLinkChanged(state: .live))
    #expect(store.updatesLink == .live)
    store.apply(
      .changedFiles(sessionId: "x", environmentId: "default", update: .unavailable(message: "x")))
    #expect(store.changedFilesRevision == 1)
  }
}
