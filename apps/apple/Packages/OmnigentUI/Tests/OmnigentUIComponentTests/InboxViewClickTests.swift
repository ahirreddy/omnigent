#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Shared items and actions for the Inbox's clicked tests.
  @MainActor
  struct InboxTestBed {
    let log = ActionLog()
    let store: UserDefaults
    let now = PreviewData.now

    init() throws {
      store = try #require(UserDefaults(suiteName: "inbox-\(UUID())"))
    }

    var actions: InboxActions {
      let log = log
      var actions = InboxActions(
        open: { log.record("open \($0.id)") }, markRead: { log.record("read \($0.id)") },
        reply: { log.record("reply \($0.id) [\($1)]") },
        respond: { log.record("respond \($0.id) \($1.summary)") })
      actions.editReply = { log.record("edited \($0.id)") }
      actions.retry = { log.record("retry") }
      actions.loadMoreSessions = { log.record("more") }
      return actions
    }

    func item(
      _ id: String, kind: InboxItem.Kind = .unread, age: TimeInterval = 60, unread: Bool = true,
      decision: DecisionCard? = nil
    ) -> InboxItem {
      InboxItem(
        id: id, kind: kind, sessionId: "session-\(id)", sessionTitle: "Title \(id)",
        preview: "Preview \(id)", date: now.addingTimeInterval(-age), isUnread: unread,
        decision: decision)
    }

    func approval(_ id: String, plan: String? = nil) -> DecisionCard {
      var card = DecisionCard(
        id: id, carryingSessionId: "session-\(id)", title: "Allow \(id)?", detail: "Details",
        kind: .approval)
      card.permissions.plan = plan
      return card
    }

    func screen(
      _ state: InboxViewState, actions: InboxActions? = nil, height: CGFloat = 900
    ) -> OffscreenWindow<some View> {
      SystemSideEffects.reset()
      var state = state
      state.now = now
      return OffscreenWindow(
        InboxView(state: state, actions: actions ?? self.actions).defaultAppStorage(store),
        width: 900, height: height)
    }

    func screen(items: [InboxItem]) -> OffscreenWindow<some View> {
      screen(InboxViewState(items: items))
    }
  }

  @Suite("Inbox keyboard and filters", .serialized)
  @MainActor
  struct InboxViewKeyboardTests {
    private let bed: InboxTestBed

    init() throws {
      bed = try InboxTestBed()
    }

    private var log: ActionLog { bed.log }

    private func press<Content>(
      _ key: String, _ screen: OffscreenWindow<Content>, modifiers: NSEvent.ModifierFlags = []
    ) throws {
      try screen.press(keyCode: 0, characters: key, modifiers: modifiers)
    }

    private func pressReturn<Content>(_ screen: OffscreenWindow<Content>) throws {
      try screen.press(keyCode: 36, characters: "\r")
    }

    @Test("clicking a row selects it, so Return opens that one")
    func clickSelects() throws {
      let screen = bed.screen(items: [bed.item("a", age: 10), bed.item("b", age: 20)])
      defer { screen.close() }
      let rows = screen.buttonFrames.filter { $0.height < 200 && $0.width > 200 }
      try #require(rows.count == 2, "\(screen.buttonFrames)")
      try screen.click(rows[1].center)
      screen.settle(0.5)
      #expect(try screen.shows("Preview b"))
      try pressReturn(screen)
      #expect(log.entries.contains("open b"), "\(log.entries)")
      #expect(!log.entries.contains("open a"), "\(log.entries)")
    }

    @Test("J and K move the selection, Return opens it, and neither end wraps")
    func letterKeys() throws {
      let screen = bed.screen(items: [
        bed.item("a", age: 10), bed.item("b", age: 20), bed.item("c", age: 30),
      ])
      defer { screen.close() }
      try pressReturn(screen)
      #expect(log.entries == ["open a"])
      try press("j", screen)
      try pressReturn(screen)
      try press("j", screen)
      try press("j", screen)
      try pressReturn(screen)
      try press("k", screen)
      try pressReturn(screen)
      #expect(log.entries == ["open a", "open b", "open c", "open b"])
    }

    @Test("the arrow keys move too")
    func arrowKeys() throws {
      let screen = bed.screen(items: [bed.item("a", age: 10), bed.item("b", age: 20)])
      defer { screen.close() }
      try screen.press(keyCode: 125, characters: "\u{F701}")
      try pressReturn(screen)
      try screen.press(keyCode: 126, characters: "\u{F700}")
      try pressReturn(screen)
      #expect(log.entries == ["open b", "open a"])
    }

    @Test("E approves the selected approval, but not a plan nobody has read")
    func approveKey() throws {
      let screen = bed.screen(items: [
        bed.item("a", kind: .approval, age: 10, decision: bed.approval("a")),
        bed.item("p", kind: .approval, age: 20, decision: bed.approval("p", plan: "# Plan")),
      ])
      defer { screen.close() }
      try press("e", screen)
      #expect(log.entries == ["respond a \(DecisionResponse.approve.summary)"])
      try press("j", screen)
      try press("e", screen)
      #expect(log.entries.count == 1, "the plan needs opening first")
    }

    @Test("E marks an update read, and does nothing to an update already read")
    func markReadKey() throws {
      let screen = bed.screen(items: [
        bed.item("a", age: 10), bed.item("b", age: 20, unread: false),
      ])
      defer { screen.close() }
      try press("e", screen)
      #expect(log.entries == ["read a"])
      try press("j", screen)
      try press("e", screen)
      #expect(log.entries == ["read a"])
    }

    @Test("a held Command leaves the list's letter keys to the menu bar")
    func modifiedKeys() throws {
      let screen = bed.screen(items: [bed.item("a", age: 10), bed.item("b", age: 20)])
      defer { screen.close() }
      try press("j", screen, modifiers: .command)
      try press("e", screen, modifiers: .command)
      #expect(log.entries.isEmpty)
      try pressReturn(screen)
      #expect(log.entries == ["open a"], "the selection didn't move")
    }

    @Test("slash moves to search, where letters type instead of moving")
    func slashToSearch() throws {
      let screen = bed.screen(items: [bed.item("a", age: 10), bed.item("b", age: 20)])
      defer { screen.close() }
      try press("/", screen)
      try screen.type("b")
      let search = try #require(screen.textFields.first)
      #expect(search.stringValue == "b")
      #expect(log.entries.isEmpty)
    }

    @Test("nothing to select leaves every key doing nothing")
    func keysOnEmpty() throws {
      let screen = bed.screen(items: [])
      defer { screen.close() }
      try press("j", screen)
      try press("e", screen)
      try pressReturn(screen)
      #expect(log.entries.isEmpty)
    }

    @Test("the filter narrows the list, and is remembered")
    func filter() throws {
      let request = bed.item(
        "r", kind: .approval, age: 10, unread: false, decision: bed.approval("r"))
      let screen = bed.screen(items: [
        request, bed.item("u", age: 20), bed.item("x", age: 30, unread: false),
      ])
      defer { screen.close() }
      #expect(try screen.shows("Preview x"))
      let control = try #require(screen.segmentedControls.first)
      try screen.click(segment: 1, of: control)
      #expect(try screen.shows("Preview u"))
      #expect(try !screen.shows("Preview x"))
      #expect(bed.store.string(forKey: "omnigent.inbox.filter") == "unread")
      try screen.click(segment: 2, of: control)
      #expect(try screen.shows("Preview r"))
      #expect(try !screen.shows("Preview u"))
    }

    @Test("search narrows the list and says when nothing matches")
    func search() throws {
      let screen = bed.screen(items: [bed.item("a", age: 10), bed.item("b", age: 20)])
      defer { screen.close() }
      let field = try #require(screen.textFields.first)
      try screen.replaceText(in: field, with: "Preview b")
      #expect(try screen.shows("Title b"))
      #expect(try !screen.shows("Title a"))
      try screen.replaceText(in: field, with: "nothing like this")
      #expect(try screen.shows("No matching items"))
    }

    @Test("each empty list says the right thing, and never too early")
    func emptyStates() throws {
      var more = InboxViewState(items: [])
      more.hasMoreSessions = true
      var assembling = InboxViewState(items: [])
      assembling.isAssembling = true
      var failed = InboxViewState(items: [])
      failed.failedSessionCount = 2
      let cases = [
        (InboxViewState(items: []), "Nothing waiting on you", true),
        (more, "Nothing waiting in these sessions", true),
        (assembling, "Loading inbox", true),
        (assembling, "Nothing waiting", false),
        (failed, "Nothing waiting", false),
      ]
      for (state, text, shown) in cases {
        let screen = bed.screen(state)
        defer { screen.close() }
        #expect(try screen.shows(text) == shown, "\(text)")
      }
    }

    @Test("the empty filters have their own words")
    func emptyFilters() throws {
      let screen = bed.screen(items: [])
      defer { screen.close() }
      let control = try #require(screen.segmentedControls.first)
      try screen.click(segment: 1, of: control)
      #expect(try screen.shows("You\u{2019}re all caught up"))
      try screen.click(segment: 2, of: control)
      #expect(try screen.shows("No approvals waiting"))
    }

    @Test("the failed count reads in good English and offers Retry")
    func failedSessions() throws {
      var one = InboxViewState(items: [bed.item("a")])
      one.failedSessionCount = 1
      let screen = bed.screen(one)
      defer { screen.close() }
      #expect(try screen.shows("from 1 session."))
      // Filter, search, Retry, then the row.
      try screen.clickControl(at: 2)
      #expect(log.entries == ["retry"])
      var two = one
      two.failedSessionCount = 2
      let plural = bed.screen(two)
      defer { plural.close() }
      #expect(try plural.shows("from 2 sessions."))
    }

    @Test("the needs-you count reads in good English; the pill counts items")
    func counts() throws {
      var state = InboxViewState(items: [bed.item("a")])
      state.needsYouCount = 1
      let one = bed.screen(state)
      defer { one.close() }
      #expect(try one.shows("1 needs you"))
      state.needsYouCount = 3
      let many = bed.screen(state)
      defer { many.close() }
      #expect(try many.shows("3 need you"))
    }

    @Test("Load more loads once, and can't be clicked again while it does")
    func loadMore() throws {
      var state = InboxViewState(items: [bed.item("a")])
      state.hasMoreSessions = true
      state.isAssembling = true
      let screen = bed.screen(state)
      defer { screen.close() }
      #expect(try screen.shows("Checking remaining sessions"))
      // The list itself is a control too, so the button is the last one of a button's height.
      let button = try #require(screen.buttonFrames.last { $0.height < 40 })
      try screen.click(CGPoint(x: button.midX, y: button.midY))
      #expect(log.entries == ["more"])
      state.isLoadingMoreSessions = true
      let loading = bed.screen(state)
      defer { loading.close() }
      #expect(try loading.shows("Loading\u{2026}"))
      #expect(log.entries == ["more"])
    }
  }
#endif
