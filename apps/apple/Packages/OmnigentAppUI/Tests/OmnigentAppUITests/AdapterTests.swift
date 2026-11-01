import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Store to view-state adapters")
struct AdapterTests {
  @Test("Connection phases map case for case, keeping the started method")
  func phases() {
    let failure = CoreError.Auth(
      kind: .unauthorized, failure: .refused(reason: "bad password"), message: "Refused",
      detail: "invalid username or password")
    let phase = SignInPhase(
      .signInRequired(
        baseUrl: "https://a.example", serverName: "A", mode: .accounts,
        methods: [.password, .browserTicket], reason: failure),
      method: nil)
    #expect(
      phase
        == .signInRequired(
          baseUrl: "https://a.example", serverName: "A", mode: .accounts,
          methods: [.password, .browserTicket],
          reason: SignInError(
            category: .auth, failure: .refused(reason: "bad password"), message: "Refused",
            serverReason: "invalid username or password")))
    #expect(
      SignInPhase(.signingIn(baseUrl: "https://a.example"), method: .password)
        == .signingIn(baseUrl: "https://a.example", method: .password))
    #expect(
      SignInPhase(.discovering(serverUrl: "a.example"), method: nil)
        == .discovering(serverUrl: "a.example"))
  }

  @Test("Core errors keep their variant and message")
  func errors() {
    let transport = SignInError(CoreError.Transport(kind: .offline, message: "offline"))
    #expect(transport.category == .transport)
    #expect(transport.isRetryable)
    #expect(transport.message == "Could not reach the server: offline")
    let status = SignInError(CoreError.HttpStatus(status: 503, body: ""))
    #expect(status.category == .httpStatus(status: 503))
  }

  @Test("Decision responses round-trip to the core's shape")
  func responses() {
    #expect(OmnigentCoreFFI.DecisionResponse(.approve) == .approve)
    #expect(
      OmnigentCoreFFI.DecisionResponse(.approvePersist(mode: .always))
        == .approvePersist(mode: .always))
    #expect(
      OmnigentCoreFFI.DecisionResponse(.form(values: ["n": .integer(value: 3)]))
        == .form(values: ["n": .integer(value: 3)]))
  }

  @Test("Session web URLs keep the server's mount path")
  func webURL() {
    let server = ConnectedServer(
      baseUrl: "https://host.example/omni/", serverName: nil, userId: "u", accountId: "a",
      mode: .oidc)
    #expect(
      SidebarAdapter.webURL(server: server, sessionID: "abc")?.absoluteString
        == "https://host.example/omni/c/abc")
  }

  @Test("The picker's URL check adds the right scheme")
  func validator() {
    #expect(ServerURLValidator.app.check("127.0.0.1:6767") == .valid(normalized: "http://127.0.0.1:6767"))
    #expect(ServerURLValidator.app.check("omnigent.example.com/") == .valid(normalized: "https://omnigent.example.com"))
    #expect(!ServerURLValidator.app.check("ftp://x").canConnect)
  }

  @Test("The demo core's sessions and a conversation reach the view state")
  func demoConversation() async throws {
    let store = try await PreviewData.connectedDemoStore()
    let deadline = ContinuousClock.now + .seconds(10)
    while store.sessionList.visible.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let first = try #require(store.sessionList.visible.first)
    let sidebar = SidebarAdapter.state(
      list: store.sessionList, notifications: store.notifications,
      display: SessionDisplayOptions(), server: store.connectedServer)
    #expect(sidebar.list.sessions.map(\.id) == store.sessionList.visible.map(\.id))
    let conversation = try #require(store.conversation(first.id))
    while conversation.rows.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let state = ConversationAdapter.state(conversation, summary: first)
    #expect(state.rows.map(\.id) == conversation.rows.map(\.id))
    #expect(state.header.id == first.id)
  }
}
