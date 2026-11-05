import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Inbox request adapter")
struct InboxPaletteAdapterTests {
  @Test("Exact commands and questions replace generic session previews")
  func payloads() {
    let command = OmnigentUIComponents.DecisionCard(
      id: "command", carryingSessionId: "session", title: "Approval required",
      detail: "Run tests", kind: .approval,
      permissions: OmnigentUIComponents.PermissionOptions(
        command: OmnigentUIComponents.CommandApproval(command: "swift test --filter AuthTests")))
    #expect(InboxTriageMapping.summaryText(command) == "swift test --filter AuthTests")
    let question = OmnigentUIComponents.DecisionCard(
      id: "question", carryingSessionId: "session", title: "Questions",
      detail: "Choose a destination",
      kind: .form(fields: [
        OmnigentUIComponents.FormField(key: "branch", title: "Which branch?", kind: .text)
      ]))
    #expect(InboxTriageMapping.summaryText(question) == "Choose a destination\nWhich branch?")
  }

  @Test(
    "Demo requests load without selecting a conversation; local reading keeps requests unresolved")
  func triage() async throws {
    let store = try await OmnigentStores.PreviewData.connectedDemoStore()
    let deadline = ContinuousClock.now + .seconds(10)
    while store.sessionList.needsResponse.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let waiting = try #require(store.sessionList.needsResponse.first)
    let conversation = try #require(store.conversation(waiting.id))
    while !conversation.isHydrated, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let state = InboxTriageMapping.state(connection: store, readRevisions: [:])
    // The header counts sessions from the shared attention model, as the sidebar and Dock do.
    #expect(state.needsYouCount == Int(store.sessionList.attentionTotals.sessionsNeedingYou))
    #expect(state.needsYouCount == store.notifications?.badgeCount)
    let request = try #require(state.items.first { $0.decision != nil })
    #expect(!request.preview.isEmpty)
    #expect(!request.agentName.isEmpty)
    #expect(request.isUnresolved)
    // Everything is read: the list no longer claims to be loading.
    #expect(!state.isAssembling)
    // As the web, a pinned session that is read and waiting on nobody is not listed.
    let listed = Set(state.items.map(\.sessionId))
    let badged = Set(store.notifications?.badgeSessionIDs ?? [])
    for pinned in store.sessionList.sessionsByID.values
    where pinned.isPinned && pinned.status == .idle
      && !store.sessionList.unreadIDs.contains(pinned.id) && !badged.contains(pinned.id)
    {
      #expect(!listed.contains(pinned.id))
    }
    let read = InboxTriageMapping.state(
      connection: store, readRevisions: [request.id: request.date.timeIntervalSince1970])
    let readRequest = try #require(read.items.first { $0.id == request.id })
    #expect(!readRequest.isUnread)
    #expect(readRequest.isUnresolved)
    #expect(readRequest.waitingSince == nil)
    store.closeConversation(waiting.id)
  }
}
