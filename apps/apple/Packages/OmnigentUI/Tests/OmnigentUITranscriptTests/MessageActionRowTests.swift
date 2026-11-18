import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Message actions")
@MainActor
struct MessageActionRowTests {
  private let forking = ConversationActions(
    forkFrom: { _ in },
    messageURL: { URL(string: "https://omnigent.example.com/c/s?message=\($0.id)") })

  private func kinds(_ row: Row, _ actions: ConversationActions) -> [MessageActionItem.Kind] {
    MessageActionItem.items(for: row, actions: actions).map(\.kind)
  }

  @Test("A settled answer offers Copy, Fork from here and Copy link, in that order")
  func answer() {
    let row = Row(id: "a1", role: .assistant, text: "Done.", responseId: "resp_1")
    let items = MessageActionItem.items(for: row, actions: forking)
    #expect(items.map(\.kind) == [.copy, .fork, .link])
    #expect(items.map(\.identifier) == ["message-copy-a1", "message-fork-a1", "message-link-a1"])
    #expect(items[1].title == "Fork from here")
    #expect(items[1].systemImage == "arrow.triangle.branch")
  }

  @Test("Fork needs a host that forks and a settled assistant message with a response")
  func forkPoints() {
    let answer = Row(id: "a1", role: .assistant, text: "Done.", responseId: "resp_1")
    #expect(!kinds(answer, ConversationActions()).contains(.fork))
    var streaming = answer
    streaming.isStreaming = true
    var preview = answer
    preview.isEphemeral = true
    var unanchored = answer
    unanchored.responseId = nil
    let user = Row(id: "u1", role: .user, text: "Hi", responseId: "turn_1")
    for row in [streaming, preview, unanchored, user] {
      #expect(!kinds(row, forking).contains(.fork), "\(row.id)")
    }
  }

  @Test("A session that can't be forked keeps Fork from here, disabled with the reason")
  func forkUnavailable() {
    var actions = ConversationActions()
    actions.forkUnavailableReason = "Only the owner can fork this session"
    let answer = Row(id: "a1", role: .assistant, text: "Done.", responseId: "resp_1")
    let fork = MessageActionItem.items(for: answer, actions: actions).first { $0.kind == .fork }
    #expect(fork?.unavailableReason == "Only the owner can fork this session")
    // Still only on fork points, and a host that forks has no reason.
    let user = Row(id: "u1", role: .user, text: "Hi", responseId: "turn_1")
    #expect(!kinds(user, actions).contains(.fork))
    actions.forkFrom = { _ in }
    #expect(MessageActionItem.items(for: answer, actions: actions)[1].unavailableReason == nil)
    // The relay republishes when the reason appears, so rows redraw.
    var reasonOnly = ConversationActions()
    reasonOnly.forkUnavailableReason = "No"
    #expect(ConversationActions().menuSignature != reasonOnly.menuSignature)
  }

  @Test("Edit and resend: the viewer's own accepted message with text, where a composer takes it")
  func editAndResend() {
    var edited: [String] = []
    var actions = ConversationActions()
    actions.editSentMessage = { edited.append($0.text) }
    actions.viewerID = "ada"
    let mine = Row(id: "u1", role: .user, text: "Fix it", author: "ada")
    let items = MessageActionItem.items(for: mine, actions: actions)
    #expect(items.map(\.kind) == [.copy, .edit])
    #expect(items[1].identifier == "message-edit-u1")
    #expect(items[1].title == "Edit and resend" && items[1].systemImage == "pencil")
    items[1].perform()
    #expect(edited == ["Fix it"])
    // A single-user message carries no author.
    #expect(kinds(Row(id: "u2", role: .user, text: "Hi"), actions).contains(.edit))
    var pending = mine
    pending.isEphemeral = true
    let other = Row(id: "u3", role: .user, text: "Hi", author: "grace")
    let blank = Row(id: "u4", role: .user, text: "  ")
    let answer = Row(id: "a1", role: .assistant, text: "Done.", responseId: "resp_1")
    for row in [pending, other, blank, answer] {
      #expect(!kinds(row, actions).contains(.edit), "\(row.id)")
    }
    #expect(!kinds(mine, ConversationActions()).contains(.edit), "a read-only composer has none")
    // The relay's forwarding copy keeps it, and rows redraw when it appears.
    let latest = actions
    let forwarded = actions.forwarding(to: { latest })
    #expect(kinds(mine, forwarded) == [.copy, .edit])
    #expect(ConversationActions().menuSignature != actions.menuSignature)
  }

  @Test("An empty message has nothing to copy")
  func emptyText() {
    let row = Row(id: "a1", role: .assistant, text: "", responseId: "resp_1")
    #expect(kinds(row, forking) == [.fork, .link])
  }

  @Test("Reply and Ask in side chat quote the whole trimmed message, when the host offers them")
  func quoteItems() {
    var replied: [String] = []
    var asked: [String] = []
    var actions = ConversationActions()
    actions.replyWithSelection = { replied.append($0) }
    actions.askInSideChat = { asked.append($0) }
    let row = Row(id: "a1", role: .assistant, text: "  Done.\n", responseId: "resp_1")
    let items = MessageActionItem.quoteItems(for: row, actions: actions)
    #expect(items.map(\.kind) == [.reply, .askSideChat])
    #expect(items.map(\.identifier) == ["message-reply-a1", "message-side-chat-a1"])
    for item in items { item.perform() }
    #expect(replied == ["Done."] && asked == ["Done."])
    // Read-only viewers get neither; Reply alone when side chats are off.
    #expect(MessageActionItem.quoteItems(for: row, actions: ConversationActions()).isEmpty)
    actions.askInSideChat = nil
    #expect(MessageActionItem.quoteItems(for: row, actions: actions).map(\.kind) == [.reply])
  }

  @Test("An empty or streaming message has nothing to quote")
  func quoteNeedsSettledText() {
    var actions = ConversationActions()
    actions.replyWithSelection = { _ in }
    let empty = Row(id: "a1", role: .assistant, text: " ", responseId: "resp_1")
    var streaming = Row(id: "a2", role: .assistant, text: "Partial", responseId: "resp_2")
    streaming.isStreaming = true
    #expect(MessageActionItem.quoteItems(for: empty, actions: actions).isEmpty)
    #expect(MessageActionItem.quoteItems(for: streaming, actions: actions).isEmpty)
  }

  @Test("A message link finds the user message by item id and an answer by its response")
  func linkedMessageRow() {
    let rows = [
      Row(id: "u1", role: .user, text: "Fix it"),
      Row(id: "a1", role: .assistant, text: "Looking.", responseId: "resp_1"),
      Row(id: "a2", role: .assistant, text: "Fixed.", responseId: "resp_1"),
    ]
    let segments = TurnLayout.segments(TranscriptLayout.items(for: rows), isRunning: false)
    #expect(TranscriptFocus.entryID(forMessage: "u1", in: segments) == "u1")
    #expect(TranscriptFocus.entryID(forMessage: "resp_1", in: segments) == "a2")
    #expect(TranscriptFocus.entryID(forMessage: "missing", in: segments) == nil)
  }

  @Test("A focused message waits per session until the transcript shows it")
  func focusQueue() {
    let focus = TranscriptFocus()
    focus.focus("m1", in: "s1")
    #expect(focus.messageID(in: "s1") == "m1")
    #expect(focus.messageID(in: "s2") == nil)
    focus.clear("s1")
    #expect(focus.messageID(in: "s1") == nil)
    focus.flash("row")
    #expect(focus.flashedRowID == "row")
  }
}
