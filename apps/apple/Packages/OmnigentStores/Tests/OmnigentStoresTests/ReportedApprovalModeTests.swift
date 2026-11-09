import OmnigentCoreFFI
import Testing

@testable import OmnigentStores

@MainActor
@Suite("The approval chip follows the mode the harness reports", .serialized)
struct ReportedApprovalModeTests {
  private func section(_ id: String, mode: String) -> EventSection {
    let detail = DetailSection(id: "mode", title: "Mode", text: mode, isCode: false)
    return EventSection(
      id: id, title: id, summary: mode, details: [detail], sessionId: nil)
  }

  private func configuration(mode: String?) -> SessionConfiguration {
    SessionConfiguration(
      agentId: "agent", harness: "codex-native", wrapper: "codex-native-ui", modelOverride: nil,
      baseModel: nil, effort: nil, modelReported: true, effortReported: true, models: [],
      hostId: "host", hostOnline: true, runnerOnline: true, runnerBound: true, hostResumable: nil,
      parentId: nil, routingMode: nil, approvalMode: mode)
  }

  private func change(_ sections: [EventSection]) -> TranscriptChange {
    TranscriptChange(rows: [], header: nil, sections: sections)
  }

  @Test("a session that never switched shows the reported mode once it arrives")
  func reportedModeSelectsTheChip() async throws {
    let gate = EventsGate()
    let (connection, conversation) = try await LiveConversationFixture.connected(gate)
    defer { connection.closeConversation(liveSessionID) }
    let composer = conversation.composer
    composer.configuration = configuration(mode: nil)
    #expect(composer.approvalModeMenu?.selected == nil)

    conversation.apply(revision: 90, change: change([section("approval", mode: "approve-for-me")]))
    #expect(composer.approvalModeMenu?.selected == "approve-for-me")
  }

  @Test("a chip switch isn't undone by an unrelated section update carrying the old report")
  func aStaleReportDoesNotUndoASwitch() async throws {
    let gate = EventsGate()
    let (connection, conversation) = try await LiveConversationFixture.connected(gate)
    defer { connection.closeConversation(liveSessionID) }
    let composer = conversation.composer
    composer.configuration = configuration(mode: nil)
    let reported = section("approval", mode: "approve-for-me")
    conversation.apply(revision: 90, change: change([reported]))

    composer.configuration = configuration(mode: "full-access")
    let other = EventSection(id: "status", title: "S", summary: "s", details: [], sessionId: nil)
    conversation.apply(revision: 91, change: change([reported, other]))
    #expect(composer.approvalModeMenu?.selected == "full-access")
  }

  @Test("a configuration read without a label keeps the mode the stream reported")
  func aLabellessReadKeepsTheReport() async throws {
    let gate = EventsGate()
    let (connection, conversation) = try await LiveConversationFixture.connected(gate)
    defer { connection.closeConversation(liveSessionID) }
    let composer = conversation.composer

    // Reported before the first read, while the composer has no configuration yet.
    conversation.apply(revision: 90, change: change([section("permission", mode: "acceptEdits")]))
    #expect(composer.configuration == nil)
    await composer.loadConfiguration()
    #expect(composer.configuration?.approvalMode == "acceptEdits")
  }

  @Test("sections without a reported mode change nothing")
  func noReportNoChange() async throws {
    let gate = EventsGate()
    let (connection, conversation) = try await LiveConversationFixture.connected(gate)
    defer { connection.closeConversation(liveSessionID) }
    let composer = conversation.composer
    composer.configuration = configuration(mode: "ask-for-approval")
    let bare = EventSection(id: "approval", title: "A", summary: "x", details: [], sessionId: nil)
    conversation.apply(revision: 90, change: change([bare]))
    #expect(composer.approvalModeMenu?.selected == "ask-for-approval")
  }
}
