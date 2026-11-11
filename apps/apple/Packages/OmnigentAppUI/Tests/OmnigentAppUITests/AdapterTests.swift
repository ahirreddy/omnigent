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

  @Test("An answer the store holds maps back to the response the card was given")
  func heldAnswers() {
    let values: [String: OmnigentUIComponents.ElicitationValue] = [
      "null": .null, "bool": .bool(value: true), "integer": .integer(value: 3),
      "number": .number(value: 1.5), "text": .text(value: "yes"),
      "list": .textList(values: ["a", "b"]),
    ]
    let responses: [OmnigentUIComponents.DecisionResponse] = [
      .approve, .decline, .cancel, .answer(value: "Sessions"), .form(values: values),
      .approveAllEdits, .approveAutoMode, .approveDirectories, .approveRemembering,
      .approveCommandPolicy(policy: ["cargo", "test"]), .approvePersist(mode: .session),
      .approvePersist(mode: .always), .declineWithFeedback(feedback: "Only the auth tests"),
    ]
    for response in responses {
      let held = OmnigentCoreFFI.DecisionResponse(response)
      #expect(OmnigentUIComponents.DecisionResponse(held) == response)
    }
  }

  @Test("A card's feedback support and a reply reach the core unchanged")
  func feedback() {
    #expect(
      OmnigentCoreFFI.DecisionResponse(.declineWithFeedback(feedback: "Only the auth tests"))
        == .declineWithFeedback(feedback: "Only the auth tests"))
    let card = OmnigentCoreFFI.DecisionCard(
      id: "e1", carryingSessionId: "s", targetSessionId: "s", title: "Approval requested",
      detail: "Claude wants to call **Bash**", message: "Claude wants to call **Bash**",
      toolInput: nil, kind: .approval,
      permissions: OmnigentCoreFFI.PermissionOptions(
        allowAllEdits: false, allowAutoMode: false, permissionDirectories: [],
        rememberLabel: nil, plan: nil, command: nil, execPolicyAmendment: nil, persistModes: [],
        antigravity: nil, fileChanges: []),
      phase: "pre_tool_use", policyName: "claude_native_permission", acceptsFeedback: true,
      answered: false)
    #expect(OmnigentUIComponents.DecisionCard(card).acceptsFeedback)
    var codex = card
    codex.acceptsFeedback = false
    #expect(!OmnigentUIComponents.DecisionCard(codex).acceptsFeedback)
  }

  @Test("An edit approval's files, message and tool input reach the card")
  func editedFiles() {
    let card = OmnigentCoreFFI.DecisionCard(
      id: "e2", carryingSessionId: "s", targetSessionId: "s", title: "Approval requested",
      detail: "Claude wants to call **Edit**\n\nEdit({...})",
      message: "Claude wants to call **Edit**", toolInput: "Edit({\n  \"file_path\": \"/a.rs\"\n})",
      kind: .approval,
      permissions: OmnigentCoreFFI.PermissionOptions(
        allowAllEdits: true, allowAutoMode: false, permissionDirectories: [],
        rememberLabel: nil, plan: nil, command: nil, execPolicyAmendment: nil, persistModes: [],
        antigravity: nil,
        fileChanges: [
          EditedFile(path: "/a.rs", kind: .modify, linesAdded: 3, linesRemoved: 1),
          EditedFile(path: "/new.rs", kind: .create, linesAdded: 12, linesRemoved: 0),
          EditedFile(path: "/cut.rs", kind: nil, linesAdded: nil, linesRemoved: nil),
        ]),
      phase: "pre_tool_use", policyName: "claude_native_permission", acceptsFeedback: true,
      answered: false)
    let state = OmnigentUIComponents.DecisionCard(card)
    #expect(
      state.permissions.files == [
        DecisionFileChange(path: "/a.rs", added: 3, removed: 1, kind: .modify),
        DecisionFileChange(path: "/new.rs", added: 12, removed: 0, kind: .create),
        DecisionFileChange(path: "/cut.rs"),
      ])
    #expect(state.message == "Claude wants to call **Edit**")
    #expect(state.toolInput == card.toolInput)
  }

  @Test("The demo core's design approval lists the files its patch changes")
  func demoEditedFiles() async throws {
    let store = try await PreviewData.connectedDemoStore()
    let conversation = try #require(store.conversation("demo-design"))
    let deadline = ContinuousClock.now + .seconds(10)
    while conversation.decisions.cards.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let card = OmnigentUIComponents.DecisionCard(try #require(conversation.decisions.cards.first))
    #expect(
      card.permissions.files == [
        DecisionFileChange(path: "Omni/iOS/SessionRow.swift", added: 4, removed: 1, kind: .modify),
        DecisionFileChange(
          path: "Omni/iOS/AttentionSection.swift", added: 11, removed: 0, kind: .create),
      ])
    #expect(card.message?.hasPrefix("Apply the sample design?") == true)
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
    #expect(
      ServerURLValidator.app.check("127.0.0.1:6767")
        == .valid(normalized: "http://127.0.0.1:6767"))
    #expect(
      ServerURLValidator.app.check("omnigent.example.com/")
        == .valid(normalized: "https://omnigent.example.com"))
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
      list: store.sessionList, display: SessionDisplayOptions(), server: store.connectedServer)
    #expect(sidebar.list.sessions.map(\.id) == store.sessionList.visible.map(\.id))
    let conversation = try #require(store.conversation(first.id))
    while conversation.rows.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let state = ConversationAdapter.state(conversation, summary: first)
    #expect(state.rows.map(\.id) == conversation.rows.map(\.id))
    #expect(state.header.id == first.id)

    // The screen around the transcript reads no rows; the transcript reads them live.
    let screen = ConversationAdapter.screenState(conversation, summary: first)
    #expect(screen.rows.isEmpty)
    #expect(screen.transcriptStatus == TranscriptStatus(rows: state.rows))
    #expect(SessionStatusLine(screen) == SessionStatusLine(state))
    let live = ConversationAdapter.liveRows(conversation).read()
    #expect(live.rows.map(\.id) == conversation.rows.map(\.id))
    #expect(live.revision == conversation.revision)
  }
}
