#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Inbox rows, clicked", .serialized)
  @MainActor
  struct InboxRowClickTests {
    private let bed: InboxTestBed

    init() throws {
      bed = try InboxTestBed()
    }

    private var log: ActionLog { bed.log }

    /// A row as the list shows it; its reply draft is held here for the test to read.
    private func row(
      _ item: InboxItem, expanded: Bool = true, draft: EditedValue<String> = EditedValue(""),
      actions: InboxActions? = nil
    ) -> OffscreenWindow<some View> {
      SystemSideEffects.reset()
      let isExpanded = EditedValue(expanded)
      let log = log
      return OffscreenWindow(
        ObservedRow(
          item: item, actions: actions ?? bed.actions, expanded: isExpanded, draft: draft,
          select: { log.record("selected") }
        ).defaultAppStorage(bed.store), width: 800, height: 500)
    }

    private func repliable(_ id: String = "a", reply: InboxReplyPhase = .idle) -> InboxItem {
      var item = bed.item(id)
      item.canReply = true
      item.reply = reply
      return item
    }

    @Test("clicking a row selects it and opens its detail, then closes it again")
    func toggle() throws {
      let screen = row(repliable(), expanded: false)
      defer { screen.close() }
      #expect(screen.textFields.isEmpty)
      try screen.clickControl(at: 0)
      #expect(log.entries == ["selected"])
      // The disclosure animates; a click needs the row where it ends up.
      screen.settle(0.5)
      #expect(screen.textFields.count == 1)
      try screen.clickControl(at: 0)
      screen.settle(0.5)
      #expect(log.entries == ["selected", "selected"])
      #expect(try !screen.shows("Open session"))
      #expect(screen.textFields.isEmpty)
    }

    @Test("a reply in flight can't be sent twice or opened away from")
    func sending() throws {
      let screen = row(repliable(reply: .sending), draft: EditedValue("Ship it"))
      defer { screen.close() }
      let field = try #require(screen.textFields.first)
      #expect(!field.isEnabled)
      for frame in screen.controlFrames { try screen.click(CGPoint(x: frame.midX, y: frame.midY)) }
      #expect(!log.entries.contains { $0.hasPrefix("reply") || $0.hasPrefix("open") })
    }

    @Test("a failed reply says why, keeps the draft, and tells the store once it's edited")
    func failed() throws {
      let draft = EditedValue("Ship it")
      let screen = row(repliable(reply: .failed(message: "The host is offline")), draft: draft)
      defer { screen.close() }
      #expect(try screen.shows("The host is offline"))
      let field = try #require(screen.textFields.first)
      #expect(field.stringValue == "Ship it")
      try screen.click(field)
      try screen.type("!")
      #expect(log.entries.contains("edited a"))
    }

    @Test("a sent reply clears the draft and says what happens next")
    func sent() throws {
      let draft = EditedValue("Ship it")
      let screen = row(repliable(reply: .sent), draft: draft)
      defer { screen.close() }
      #expect(try screen.shows("Reply sent."))
      #expect(draft.value.isEmpty)
      #expect(screen.textFields.isEmpty)
    }

    @Test("no reply field without editor access or a reply action")
    func noReply() throws {
      let readOnly = row(bed.item("a"))
      defer { readOnly.close() }
      #expect(readOnly.textFields.isEmpty)
      var actions = bed.actions
      actions.reply = nil
      let noAction = row(repliable(), actions: actions)
      defer { noAction.close() }
      #expect(noAction.textFields.isEmpty)
    }

    @Test("Open and Mark as read act on the row; a read row has no Mark as read")
    func rowActions() throws {
      let screen = row(bed.item("a"))
      defer { screen.close() }
      #expect(try screen.shows("Open session"))
      // The summary, Open session, Mark as read.
      try screen.clickControl(at: 1)
      #expect(log.entries == ["open a"])
      try screen.clickControl(at: 2)
      #expect(log.entries == ["open a", "read a"])
      let read = row(bed.item("b", unread: false))
      defer { read.close() }
      #expect(try !read.shows("Mark as read"))
      #expect(try read.shows("Read"))
    }

    @Test("a right click offers the same actions")
    func contextMenu() throws {
      let screen = row(bed.item("a"))
      defer { screen.close() }
      let summary = try #require(screen.controlFrames.first)
      let menu = try #require(
        try screen.contextMenu(at: CGPoint(x: summary.midX, y: summary.midY)))
      #expect(menu.items.map(\.title) == ["Open session", "Mark as read"])
      try screen.choose("Mark as read", in: menu)
      #expect(log.entries == ["read a"])
    }

    @Test("a comment shows who said what where, and opens its file")
    func comment() throws {
      var item = bed.item("c", kind: .comment)
      item.comment = InboxComment(
        author: "Rosalind", path: "src/app.rs", anchor: "  let retry = 3;\n", body: "Why three?")
      let screen = row(item)
      defer { screen.close() }
      #expect(try screen.shows("Rosalind commented on src/app.rs"))
      #expect(try screen.shows("let retry = 3;"))
      #expect(try screen.shows("Open file"))
      #expect(screen.allViews.contains { ($0 as? NSTextField)?.stringValue == "Why three?" })
    }

    @Test("a request whose details haven't arrived says so rather than offering an answer")
    func unresolvedWithoutDetails() throws {
      let screen = row(bed.item("q", kind: .question))
      defer { screen.close() }
      #expect(try screen.shows("Needs you"))
      #expect(try screen.shows("Details are not available yet."))
    }

    @Test("a request answers in place, for the card it belongs to")
    func decision() throws {
      let screen = row(bed.item("a", kind: .approval, decision: bed.approval("a")))
      defer { screen.close() }
      let answers = screen.buttonFrames
      #expect(answers.count >= 2)
      for frame in answers where !log.entries.contains(where: { $0.hasPrefix("respond") }) {
        try screen.click(CGPoint(x: frame.midX, y: frame.midY))
      }
      #expect(log.entries.contains { $0.hasPrefix("respond a") }, "\(log.entries)")
    }

    @Test(
      "the label reads what the row is",
      arguments: [
        (InboxItem.Kind.unread, false, "Done"), (.unread, true, "Error"),
        (.comment, false, "Comment"),
      ])
    func labels(kind: InboxItem.Kind, isError: Bool, label: String) throws {
      var item = bed.item("a", kind: kind)
      item.isError = isError
      let screen = row(item, expanded: false)
      defer { screen.close() }
      #expect(try screen.shows(label))
    }

    @Test("a row's headline is never blank")
    func headlines() throws {
      var noPreview = bed.item("a", kind: .approval, decision: bed.approval("a"))
      noPreview.preview = "  \n"
      let titled = row(noPreview, expanded: false)
      defer { titled.close() }
      #expect(try titled.shows("Allow a?"))
      var bare = bed.item("b", kind: .comment)
      bare.preview = ""
      let fallback = row(bare, expanded: false)
      defer { fallback.close() }
      #expect(try fallback.shows("Comment"))
    }

    @Test("pinned, unread, waiting time and where it runs all show")
    func details() throws {
      var item = bed.item("a", kind: .question, age: 3_600)
      item.isPinned = true
      item.waitingSince = bed.now.addingTimeInterval(-120)
      item.agentName = "Codex"
      item.executionContext = "Build Mac"
      SystemSideEffects.reset()
      let screen = OffscreenWindow(
        InboxRow(
          item: item, now: bed.now, actions: bed.actions, isSelected: true, select: {},
          isExpanded: .constant(false), reply: .constant("")
        ).defaultAppStorage(bed.store), width: 800, height: 300)
      defer { screen.close() }
      let shown = try screen.shownText()
      #expect(shown.contains("Pinned"))
      #expect(shown.contains("Unread"))
      #expect(shown.contains("Title a \u{00B7} Codex"))
      #expect(shown.contains("Build Mac"))
      #expect(shown.contains { $0.hasPrefix("Waiting ") }, "\(shown)")
    }

    @Test("a long reply offers the whole text")
    func fullReply() throws {
      var item = bed.item("a")
      item.fullText = "The **whole** reply"
      let screen = row(item)
      defer { screen.close() }
      #expect(try screen.shows("Show full reply"))
      // The summary, Show full reply.
      try screen.clickControl(at: 1)
      screen.settle()
      #expect(log.entries.isEmpty)
    }

    @Test("each kind has its tile")
    func tiles() throws {
      var comment = bed.item("c", kind: .comment)
      comment.comment = InboxComment(author: "Rosalind Franklin", path: "a", body: "b")
      var failed = bed.item("f")
      failed.isError = true
      let items = [
        comment, failed, bed.item("u"), bed.item("a", kind: .approval),
        bed.item("q", kind: .question),
        bed.item("o", kind: .comment),
      ]
      for item in items {
        SystemSideEffects.reset()
        let screen = OffscreenWindow(InboxKindTile(item: item), width: 80, height: 80)
        defer { screen.close() }
        if item.comment != nil { #expect(try screen.shows("RF")) }
      }
      #expect(InboxKindTile(item: bed.item("a", kind: .approval)).symbol == "hand.raised")
      #expect(InboxKindTile(item: bed.item("q", kind: .question)).symbol == "hand.raised")
      #expect(InboxKindTile(item: bed.item("o", kind: .comment)).symbol == "text.bubble")
      #expect(InboxKindTile(item: bed.item("u")).symbol == "checkmark.circle")
      #expect(InboxKindTile(item: failed).symbol == "exclamationmark.circle")
    }
  }

  @MainActor
  extension InboxRowClickTests {
    @Test("Send sends the draft as typed, and stays off until there's something to send")
    func sendButton() throws {
      let draft = EditedValue("")
      let screen = row(repliable(), draft: draft)
      defer { screen.close() }
      let field = try #require(screen.textFields.first)
      try screen.replaceText(in: field, with: "   ")
      #expect(log.entries.isEmpty)
      // A blank draft leaves Send disabled, so Return can't send it either.
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.entries.isEmpty)
      try screen.replaceText(in: field, with: "Ship it")
      #expect(draft.value == "Ship it")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.entries == ["reply a [Ship it]"])
    }

    @Test("with the Command-Return setting, Return is a new line and Command-Return sends")
    func commandReturnSetting() throws {
      bed.store.set(true, forKey: ComposerPreferences.submitWithCommandReturnKey)
      let draft = EditedValue("")
      let screen = row(repliable(), draft: draft)
      defer { screen.close() }
      let field = try #require(screen.textFields.first)
      try screen.replaceText(in: field, with: "One")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.entries.isEmpty)
      #expect(draft.value.hasPrefix("One"))
      #expect(draft.value.contains("\n"))
      try screen.press(keyCode: 36, characters: "\r", modifiers: .command)
      #expect(log.entries == ["reply a [One\n]"])
    }

    @Test("the Command-Return setting turned on under a shown row is the row's from then on")
    func commandReturnSettingChanges() throws {
      let draft = EditedValue("")
      let screen = row(repliable(), draft: draft)
      defer { screen.close() }
      let field = try #require(screen.textFields.first)
      try screen.replaceText(in: field, with: "One")
      bed.store.set(true, forKey: ComposerPreferences.submitWithCommandReturnKey)
      screen.settle()
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.entries.isEmpty)
      try screen.press(keyCode: 36, characters: "\r", modifiers: .command)
      #expect(log.entries == ["reply a [One\n]"])
    }

    @Test("clicking Send sends what's typed")
    func clickSend() throws {
      let screen = row(repliable(), draft: EditedValue("Ship it"))
      defer { screen.close() }
      // Send sits beside the reply field.
      let field = try #require(screen.textFields.first)
      let box = field.convert(field.bounds, to: screen.activeWindow.contentView)
      let send = try #require(
        screen.buttonFrames.first { $0.minX >= box.maxX && abs($0.midY - box.midY) < 20 })
      try screen.click(send.center)
      #expect(log.entries == ["reply a [Ship it]"])
    }
  }

  /// A row whose expansion and draft live in `EditedValue`s, as the list keeps them.
  private struct ObservedRow: View {
    let item: InboxItem
    let actions: InboxActions
    let expanded: EditedValue<Bool>
    let draft: EditedValue<String>
    let select: () -> Void

    var body: some View {
      InboxRow(
        item: item, now: PreviewData.now, actions: actions, isSelected: true, select: select,
        isExpanded: expanded.binding, reply: draft.binding)
    }
  }

  @Suite("Inbox sample triage", .serialized)
  @MainActor
  struct InboxPlaygroundTests {
    @Test("the sample counts sessions that need you, not requests")
    func needsYouCount() {
      let state = InboxTriageSamples.state
      #expect(state.needsYouCount == InboxTriageSamples.sessionsNeedingYou(state.items))
      #expect(state.items.contains { $0.isPinned })
    }

    @Test("Return opens the selected request in its sheet, and Back returns")
    func openAndBack() throws {
      SystemSideEffects.reset()
      let screen = OffscreenWindow(InboxTriagePlayground(), width: 900, height: 900)
      defer { screen.close() }
      try screen.press(keyCode: 36, characters: "\r")
      screen.settle(0.3)
      #expect(screen.window.attachedSheet != nil)
      try screen.clickControl(at: 0)
      screen.settle(0.3)
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("E answers the selected request in place, and the session needs you until all are")
    func approveInPlace() throws {
      SystemSideEffects.reset()
      let screen = OffscreenWindow(InboxTriagePlayground(), width: 900, height: 900)
      defer { screen.close() }
      let items = InboxTriageSamples.state.items
      let answered = DecisionResponse.approve.summary
      #expect(try !screen.shows(answered))
      #expect(try screen.shows("\(InboxTriageSamples.sessionsNeedingYou(items)) need"))
      // The list's own order puts a question first, which E leaves for the row's own buttons.
      try screen.press(keyCode: 0, characters: "e")
      #expect(try !screen.shows(answered))
      for _ in items where try !screen.shows(answered) {
        try screen.press(keyCode: 0, characters: "j")
        try screen.press(keyCode: 0, characters: "e")
      }
      #expect(try screen.shows(answered))
    }
  }
#endif
