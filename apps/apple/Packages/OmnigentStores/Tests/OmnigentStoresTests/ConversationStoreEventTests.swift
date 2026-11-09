import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// A transcript row with only what these tests read.
nonisolated func transcriptRow(
  _ id: String, role: RowRole = .assistant, text: String = "", activityOnly: Bool = false,
  responseID: String? = nil, interrupted: Bool = false, activity: Activity? = nil
) -> Row {
  Row(
    id: id, role: role, text: text, isStreaming: false, activity: activity, attachments: [],
    callId: nil, responseId: responseID, interrupted: interrupted, author: nil, agent: nil,
    createdAt: nil, isEphemeral: false, isActivityOnly: activityOnly)
}

/// A session header with only what these tests read.
func sessionHeader(
  _ id: String = "conv_a", status: TurnStatus = .idle, placeholder: Bool = false
) -> SessionHeader {
  SessionHeader(
    id: id, title: id, status: status, readOnly: false, archived: false, permissionLevel: 4,
    failureMessage: nil, settings: nil, isPlaceholder: placeholder)
}

/// What the conversation does with each event the core sends, in any order.
@MainActor
@Suite("Conversation events", .timeLimit(.minutes(1)))
struct ConversationStoreEventTests {
  private func conversation(
    _ server: RouteServer = RouteServer()
  ) async throws -> (ConnectionStore, ConversationStore) {
    let store = try await connectedStore(server)
    return (store, try #require(store.conversation("conv_a")))
  }

  private func change(_ ops: [RowOp], header: SessionHeader? = nil) -> TranscriptChange {
    TranscriptChange(rows: ops, header: header, sections: nil)
  }

  private func reset(_ conversation: ConversationStore, rows: [Row], revision: UInt64 = 1) {
    conversation.reset(
      revision: revision, rows: rows, header: sessionHeader(), sections: [], decisions: [])
  }

  @Test("A reset replaces everything; the core's stand-in header reads as still loading")
  func resets() async throws {
    let (_, conversation) = try await conversation()
    conversation.reset(
      revision: 3, rows: [transcriptRow("a")], header: sessionHeader(placeholder: true),
      sections: [], decisions: [])
    #expect(conversation.header == nil)
    #expect(conversation.revision == 3)
    reset(conversation, rows: [transcriptRow("b")], revision: 4)
    #expect(conversation.rows.map(\.id) == ["b"])
    #expect(conversation.header?.id == "conv_a")
  }

  @Test("Changes apply in order, and a stand-in header never replaces a real one")
  func appliesChanges() async throws {
    let (_, conversation) = try await conversation()
    reset(conversation, rows: [transcriptRow("a")])
    conversation.apply(
      revision: 2,
      change: change(
        [.insert(index: 1, row: transcriptRow("b")), .remove(id: "a")],
        header: sessionHeader(placeholder: true)))
    #expect(conversation.rows.map(\.id) == ["b"])
    #expect(conversation.revision == 2)
    #expect(conversation.header?.id == "conv_a")
    #expect(conversation.errors.isEmpty)
  }

  // Duplicates and reordering surface here: the core's ops no longer fit the store's rows.
  @Test(
    "An op that doesn't fit is reported and doesn't advance the revision",
    arguments: [
      RowOp.update(index: 0, row: transcriptRow("other")),
      RowOp.update(index: 9, row: transcriptRow("a")),
      RowOp.remove(id: "missing"),
      RowOp.insert(index: 9, row: transcriptRow("late")),
    ])
  func mismatchedOps(misfit: RowOp) async throws {
    let (_, conversation) = try await conversation()
    reset(conversation, rows: [transcriptRow("a")], revision: 5)
    conversation.apply(revision: 6, change: change([misfit]))
    #expect(conversation.revision == 5)
    guard case .RowOps = conversation.errors.last else {
      Issue.record("errors: \(conversation.errors)")
      return
    }
  }

  @Test("A store that diverged from the core is repaired by a full reset")
  func divergenceRecovers() async throws {
    let store = try await PreviewData.connectedDemoStore()
    try await eventually("the sample list") { !store.sessionList.sessionsByID.isEmpty }
    let id = try #require(store.sessionList.sessionsByID.keys.min())
    let conversation = try #require(store.conversation(id))
    try await eventually("the session") { conversation.isHydrated && !conversation.rows.isEmpty }
    let expected = conversation.rows

    conversation.apply(
      revision: conversation.revision + 1, change: change([.remove(id: "not a row")]))
    #expect(conversation.errors.count == 1)
    try await eventually("the reset") { conversation.rows == expected }
    store.closeConversation(id)
  }

  @Test("Rows split into transcript and activity")
  func rowKinds() async throws {
    let (_, conversation) = try await conversation()
    reset(conversation, rows: [transcriptRow("a"), transcriptRow("b", activityOnly: true)])
    #expect(conversation.transcriptRows.map(\.id) == ["a"])
    #expect(conversation.activityRows.map(\.id) == ["b"])
  }

  @Test("Losing the link marks the view stale and keeps why; only hydration restores it")
  func linkLoss() async throws {
    let (_, conversation) = try await conversation()
    conversation.hydrated()
    #expect(conversation.isHydrated)

    let reason = CoreError.InvalidState(message: "dropped")
    conversation.linkChanged(.reconnecting(reason: reason, failures: 1, delayMs: 100))
    #expect(!conversation.isHydrated)
    #expect(conversation.errors == [reason])

    conversation.linkChanged(.live)
    #expect(conversation.link == .live)
    #expect(!conversation.isHydrated, "live isn't caught up until hydration says so")
    conversation.hydrated()
    #expect(conversation.isHydrated)

    let fatal = CoreError.InvalidState(message: "gone")
    conversation.linkChanged(.failed(error: fatal))
    #expect(conversation.errors.last == fatal)
    conversation.linkChanged(.connecting)
    #expect(conversation.errors.count == 2, "a plain state change adds no failure")
    conversation.dismissErrors()
    #expect(conversation.errors.isEmpty)
  }

  @Test("Failures keep the newest fifty")
  func errorCap() async throws {
    let (_, conversation) = try await conversation()
    for index in 0..<55 { conversation.record(.InvalidState(message: "\(index)")) }
    #expect(conversation.errors.count == 50)
    #expect(conversation.errors.first?.message == "5")
  }

  @Test("A sleeping runner is a panel state, not a session error, until the runner returns")
  func runnerAsleep() async throws {
    let (_, conversation) = try await conversation()
    let asleep = CoreError.Terminal(
      kind: .runnerUnavailable, message: "asleep", requiresSignIn: false)
    conversation.record(asleep)
    conversation.record(asleep)
    #expect(conversation.runnerUnavailable == asleep)
    #expect(conversation.errors.isEmpty)

    reset(conversation, rows: [])
    #expect(conversation.runnerUnavailable == asleep, "an idle header doesn't wake it")
    conversation.apply(revision: 2, change: change([], header: sessionHeader(status: .running)))
    #expect(conversation.runnerUnavailable == nil)
    #expect(conversation.isRunning)
  }

  @Test("Closing and being superseded are remembered")
  func endings() async throws {
    let (_, conversation) = try await conversation()
    conversation.hydrated()
    conversation.closed()
    conversation.closed()
    #expect(conversation.isClosed)
    #expect(!conversation.isHydrated)
    conversation.superseded(by: "conv_b")
    #expect(conversation.supersededBy == "conv_b")
    conversation.failure("Turn failed")
    #expect(conversation.lastFailure == "Turn failed")
  }

  @Test("Older history is only asked for when there is some and none is loading")
  func olderHistory() async throws {
    let server = RouteServer()
    let (_, conversation) = try await conversation(server)
    let reads = server.requests(to: "/v1/sessions/conv_a/items").count
    conversation.loadOlderHistory()
    conversation.historyPagingChanged(hasOlder: true, isLoading: true)
    #expect(conversation.hasOlderHistory)
    #expect(conversation.isLoadingOlderHistory)
    conversation.loadOlderHistory()
    #expect(server.requests(to: "/v1/sessions/conv_a/items").count == reads)
    conversation.historyPagingChanged(hasOlder: false, isLoading: false)
    #expect(!conversation.hasOlderHistory)
  }

  @Test("Stopping shows idle at once, and a refusal puts the running status back")
  func interruptRollsBack() async throws {
    let server = RouteServer()
    server.fail("/v1/sessions/conv_a/events", method: "POST")
    let (store, conversation) = try await conversation(server)
    store.sessionList.apply(
      .reset(sessions: [
        SessionSummary(
          id: "conv_a", title: "a", preview: "", status: .running, pendingRequests: 0,
          isReadOnly: false, updatedAt: 1, workspace: "", agentName: "", isPinned: false,
          isArchived: false, permissionLevel: 4, failureMessage: nil, canRename: true,
          canPin: true, canArchive: true)
      ]))
    await conversation.interrupt()
    #expect(store.sessionList.session("conv_a")?.status == .running)
    #expect(!conversation.errors.isEmpty)
  }

  @Test("Export and previews throw what the server refused; agent info keeps its failure")
  func reads() async throws {
    let (_, conversation) = try await conversation()
    await #expect(throws: CoreError.self) { try await conversation.exportTranscript() }
    await #expect(throws: CoreError.self) {
      try await conversation.attachmentPreview(reference: "file_1")
    }
    await conversation.loadAgentInfo(agentID: "ag_1")
    #expect(conversation.agentInfo == nil)
    #expect(conversation.errors.count == 1)
    await conversation.recoverTurn(.resume)
    #expect(conversation.errors.count == 2)
  }

  @Test("The status line's facts ignore activity rows and read the latest tool")
  func digest() {
    #expect(TranscriptDigest(rows: []).isEmpty)
    let hidden = transcriptRow("a", activityOnly: true, interrupted: true)
    #expect(TranscriptDigest(rows: [hidden]).isEmpty)
    #expect(!TranscriptDigest(rows: [hidden]).lastInterrupted)
    let digest = TranscriptDigest(rows: [
      transcriptRow("a"), transcriptRow("b", interrupted: true), hidden,
    ])
    #expect(digest.lastInterrupted)
    #expect(digest.activityTitle == nil)
  }
}
