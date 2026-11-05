import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
@Suite("Session tools adapter")
struct SessionToolsAdapterTests {
  private let routes = SessionToolsAdapter.Routes(
    openSession: { _ in }, showPullRequests: {}, showGoal: {}, report: { _ in })

  private func loaded(_ id: String, in store: ConnectionStore) async throws -> ConversationStore {
    let conversation = try #require(store.conversation(id))
    let deadline = ContinuousClock.now + .seconds(10)
    while conversation.header?.settings?.harness == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    return conversation
  }

  @Test("A Codex-native session offers side chat, a managed goal and plan mode")
  func codexNativeTools() async throws {
    let store = try await PreviewData.connectedDemoStore()
    let conversation = try await loaded("demo-design", in: store)
    var extras = ComposerExtraActions()
    SessionToolsAdapter.add(to: &extras, store: conversation, summary: nil, routes: routes)
    #expect(extras.newSideChat != nil)
    #expect(extras.setGoal != nil)
    #expect(extras.togglePlan != nil)
    #expect(!extras.isPlanOn)
    #expect(extras.indicators.openGoal != nil)
    #expect(SessionToolsAdapter.goalControl(conversation, summary: nil) == .managed)
    let sheet = try #require(SessionToolsAdapter.goalSheet(conversation, summary: nil))
    #expect(sheet.mode == .managed(goal: nil))
    #expect(!sheet.isReadOnly)
  }

  @Test("A read-only viewer can see the goal but not start side chats or change plan mode")
  func readOnlyTools() async throws {
    let store = try await PreviewData.connectedDemoStore()
    let conversation = try await loaded("demo-notes", in: store)
    var extras = ComposerExtraActions()
    SessionToolsAdapter.add(to: &extras, store: conversation, summary: nil, routes: routes)
    #expect(extras.newSideChat == nil)
    #expect(extras.togglePlan == nil)
    #expect(extras.setGoal != nil)
    #expect(SessionToolsAdapter.goalSheet(conversation, summary: nil)?.isReadOnly == true)
  }

  @Test("A goal maps to the tray pill with its usage")
  func goalPill() {
    let goal = SessionGoal(
      objective: "Ship it", status: "paused", tokenBudget: 40_000, tokensUsed: 1_200,
      timeUsedSeconds: 180, canPause: false, canResume: true)
    let pill = SessionToolsAdapter.goal(goal)
    #expect(pill.objective == "Ship it")
    #expect(pill.canResume && !pill.canPause)
    #expect(pill.usage == "1,200 / 40,000 tokens \u{00B7} 3 min")
  }
}
