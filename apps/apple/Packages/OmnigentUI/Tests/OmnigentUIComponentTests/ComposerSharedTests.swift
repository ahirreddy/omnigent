import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// What the chat and CLI composers share, so the CLI style changes presentation only.
@Suite("Composer behaviour shared by both transcript styles")
@MainActor
struct ComposerSharedTests {
  private static func state(mentionsNote: String? = nil) -> ComposerViewState {
    var state = ComposerViewState()
    state.slashCommands = [SlashCommand(name: "help"), SlashCommand(name: "context")]
    state.mentionCandidates = ["Sources/App.swift", "Sources/"]
    state.slashCommandsNote = "Skills load when the agent starts"
    state.mentionsNote = mentionsNote
    return state
  }

  @Test("completions are offered until Esc dismisses them for that exact draft")
  func offeredCompletions() {
    let state = Self.state()
    #expect(ComposerCompletions.offered(draft: "/", dismissed: nil, state: state).items.count == 2)
    #expect(ComposerCompletions.offered(draft: "/", dismissed: "/", state: state).items.isEmpty)
    #expect(
      ComposerCompletions.offered(draft: "/c", dismissed: "/", state: state).items.map(\.title)
        == ["/context"], "typing on brings them back")
    let mention = ComposerCompletions.offered(draft: "see @App", dismissed: nil, state: state)
    #expect(mention.items.first?.mentionPath == "Sources/App.swift")
  }

  @Test("the note follows what is typed; a failed mention search explains the empty list")
  func notes() {
    let state = Self.state(mentionsNote: "File search failed")
    #expect(ComposerCompletions.note(draft: "/", state: state) == state.slashCommandsNote)
    #expect(ComposerCompletions.note(draft: "@x", state: state) == "File search failed")
    #expect(
      ComposerCompletions.failedMentionNote(draft: "@zzz", dismissed: nil, state: state)
        == "File search failed")
    #expect(
      ComposerCompletions.failedMentionNote(draft: "@zzz", dismissed: "@zzz", state: state) == nil)
    #expect(
      ComposerCompletions.failedMentionNote(draft: "/he", dismissed: nil, state: state) == nil)
  }

  @Test("perform sends, queues, or does nothing while the rules block it")
  func perform() {
    var sent = 0
    var queued = 0
    let actions = ComposerActions(
      send: { sent += 1 }, extras: ComposerExtraActions(queueDraft: { queued += 1 }))
    let idle = ComposerViewState()
    #expect(
      !actions.perform(.send, rules: ComposerSendRules(state: idle, draft: " ", canQueue: true)))
    #expect(sent == 0, "an empty draft sends nothing")
    #expect(
      actions.perform(.send, rules: ComposerSendRules(state: idle, draft: "hi", canQueue: true)))
    #expect(sent == 1)
    var mentionOnly = idle
    mentionOnly.mentions = ["Sources/App.swift"]
    #expect(
      actions.perform(
        .send, rules: ComposerSendRules(state: mentionOnly, draft: "", canQueue: true)),
      "an attached mention is something to send")
    let running = ComposerViewState(isRunning: true)
    #expect(
      actions.perform(
        .queue, rules: ComposerSendRules(state: running, draft: "next", canQueue: true)))
    #expect(queued == 1 && sent == 2)
  }

  @Test("a failed turn's recovery reads the same in both styles")
  func recoveryTitles() {
    #expect(FailureRecovery.continue.title == "Retry")
    #expect(FailureRecovery.resume.title == "Resume")
    #expect(FailureRecovery.resume.help.contains("Restart"))
  }

  @Test("the Mac's pill over the column leaves room under the last row; beside it, none")
  func navigatorClearance() {
    let pill = Theme.Control.target * 2 + Theme.Spacing.medium
    #expect(
      TranscriptNavigator.bottomClearance(layout: .card, width: 900, column: .infinity) == pill,
      "CLI edge to edge: the last row clears the pill")
    #expect(TranscriptNavigator.bottomClearance(layout: .card, width: 800, column: 760) == pill)
    #expect(
      TranscriptNavigator.bottomClearance(layout: .card, width: 1_400, column: 760) == 0,
      "the column leaves the pill its own lane")
    #expect(
      TranscriptNavigator.bottomClearance(layout: .touch, width: 390, column: .infinity) == 0,
      "touch hides the pill over the column instead")
  }

  @Test("the CLI shows the latest settled answer's actions on touch, as chat does")
  func cliLatestAnswerActions() {
    let rows = [
      Row(id: "u1", role: .user, text: "Fix the bug"),
      Row(id: "a1", role: .assistant, text: "Looking", responseId: "r1"),
      Row(id: "u2", role: .user, text: "And add tests"),
      Row(id: "a2", role: .assistant, text: "Done", responseId: "r2"),
    ]
    let idle = ConversationViewState(
      header: SessionHeader(id: "sess", title: "CLI", status: .idle), rows: rows)
    let decorations = TranscriptLayoutMemo().blocks(for: idle).reduce(
      into: [String: MessageDecoration]()
    ) {
      $0.merge($1.decorations) { first, _ in first }
    }
    #expect(decorations["a2"]?.showsActions == true)
    #expect(decorations["a1"]?.showsActions == false)
    #expect(decorations["u2"]?.showsActions == false)

    var running = idle
    running.header.status = .running
    let live = TranscriptLayoutMemo().blocks(for: running).reduce(
      into: [String: MessageDecoration]()
    ) {
      $0.merge($1.decorations) { first, _ in first }
    }
    #expect(live["a2"]?.showsActions == false, "nothing pinned while a turn runs")
  }
}
