import Foundation
import Testing

@testable import OmnigentUIComponents

/// The words the app shows for each state, and the small rules next to them.
@Suite("View state: labels")
struct ViewStateLabelTests {
  @Test("A canvas card's state reads as itself")
  func canvasStates() {
    let labels = [CanvasCard.State.needsYou, .running, .unread, .failed, .idle].map(\.label)
    #expect(labels == ["Needs you", "Running", "New messages", "Failed", "Idle"])
  }

  @Test("A canvas starts with the words and flags it needs, and holds a card as given")
  func canvasValues() {
    let board = CanvasBoard(id: "b", name: "Board", icon: "star")
    let card = CanvasCard(
      id: "c", title: "T", state: .idle, workspace: "/w", branch: "main", left: 3, top: 4)
    let state = CanvasViewState(boards: [board], activeBoard: "b", cards: [card])
    #expect(state.emptyTitle == "No sessions")
    #expect(!state.isLoading)
    #expect(state.cards.first?.left == 3)
    #expect(state.boards.first?.icon == "star")
    #expect(CanvasActions().open == nil)
  }

  @Test("An undo banner names what it undoes, and counts archived sessions")
  func undoBanner() {
    #expect(UndoBanner(id: "u", kind: .unpinned).message == "Unpinned session")
    #expect(UndoBanner(id: "u", kind: .pinned).message == "Pinned session")
    #expect(UndoBanner(id: "u", kind: .archived(count: 1)).message == "Archived 1 session")
    #expect(UndoBanner(id: "u", kind: .archived(count: 3)).message == "Archived 3 sessions")
  }

  @Test("A session's status and failure decide its attention, most urgent first")
  func attention() {
    #expect(SessionAttentionState(status: .needsResponse, failure: nil) == .needsYou)
    #expect(SessionAttentionState(status: .running, failure: "x") == .working)
    #expect(SessionAttentionState(status: .idle, failure: nil) == .idle)
    #expect(SessionAttentionState(status: .idle, failure: "x") == .failed)
    #expect(
      SessionAttentionState.allCases.map(\.label) == [
        "Needs you", "Failed", "Running", "Unread", "Idle",
      ])
    #expect(SessionAttentionState.allCases.sorted() == SessionAttentionState.allCases)
    #expect(SessionAttentionState.needsYou < .idle)
  }

  @Test("Only a session destination has a session id")
  func destinations() {
    #expect(SidebarDestination.session("s").sessionID == "s")
    for other in [SidebarDestination.newSession, .inbox, .canvas, .automations, .usage] {
      #expect(other.sessionID == nil)
    }
  }

  @Test("Project sorts and moves name themselves")
  func projectWords() {
    #expect(ProjectSort.allCases.map(\.title) == ["Alphabetically", "Manual order"])
    #expect(
      ProjectMove.allCases.map(\.title) == [
        "Move up", "Move down", "Move to top", "Move to bottom",
      ])
    #expect(ProjectMove.top.id == "top")
  }

  @Test("Settings panes name themselves; only the admin ones say so")
  func settingsPanes() {
    #expect(
      ServerSettingsPane.allCases.map(\.title) == [
        "Account", "Harnesses", "Custom Agents", "MCP", "Sandbox Integrations", "Git",
        "Import Sessions", "Members", "Policies", "Sharing", "Archived Sessions",
      ])
    #expect(ServerSettingsPane.allCases.filter(\.isAdmin) == [.members, .policies, .sharing])
    #expect(
      Set(ServerSettingsPane.allCases.map(\.systemImage)).count == ServerSettingsPane.allCases.count
    )
    #expect(ServerSettingsPane.git.id == .git)
  }

  @Test("A reported value is only a value when one was reported")
  func reportedValue() {
    #expect(ReportedValue.value(value: "x").reportedValue == "x")
    #expect(ReportedValue.harnessDefault.reportedValue == nil)
    #expect(ReportedValue.notReported.reportedValue == nil)
  }

  @Test("Retention: a stored number of days, its title, and what has expired")
  func retention() {
    #expect(ArchivedRetention.days("7") == 7)
    #expect(ArchivedRetention.days("0") == nil)
    #expect(ArchivedRetention.days("soon") == nil)
    #expect(ArchivedRetention.days(nil) == nil)
    #expect(ArchivedRetention.title(7) == "After 7 days")
    #expect(ArchivedRetention.title(nil) == "Never")
  }

  @Test("The send intent's label and its alternative")
  func sendIntent() {
    #expect(ComposerSendIntent.send.label == nil)
    #expect(ComposerSendIntent.steer.label == "Send now \u{00B7} steer")
    #expect(ComposerSendIntent.queue.label == "Queued \u{00B7} after this turn")
    #expect(ComposerSendIntent.send.alternative(canSteer: true, canQueue: true) == nil)
    #expect(ComposerSendIntent.steer.alternative(canSteer: true, canQueue: true) == .queue)
    #expect(ComposerSendIntent.steer.alternative(canSteer: true, canQueue: false) == nil)
    #expect(ComposerSendIntent.queue.alternative(canSteer: true, canQueue: true) == .steer)
    #expect(ComposerSendIntent.queue.alternative(canSteer: false, canQueue: true) == nil)
  }

  @Test("What Send does: with no queue support, steer or queue while running, else send")
  func sendIntentResolve() {
    func resolve(
      running: Bool, steer: Bool, hasQueue: Bool = false, queue: Bool, prefers: Bool = true
    ) -> ComposerSendIntent {
      ComposerSendIntent.resolve(
        isRunning: running, canSteer: steer, hasQueue: hasQueue, canQueue: queue,
        prefersSteer: prefers)
    }
    #expect(resolve(running: true, steer: true, queue: false) == .steer)
    #expect(resolve(running: true, steer: false, queue: false) == .queue)
    #expect(resolve(running: false, steer: true, queue: false) == .send)
    #expect(resolve(running: false, steer: true, hasQueue: true, queue: true) == .queue)
    #expect(resolve(running: false, steer: true, queue: true) == .send)
    #expect(resolve(running: true, steer: true, queue: true) == .steer)
    #expect(resolve(running: true, steer: true, queue: true, prefers: false) == .queue)
    #expect(resolve(running: true, steer: false, queue: true) == .queue)
  }
}
