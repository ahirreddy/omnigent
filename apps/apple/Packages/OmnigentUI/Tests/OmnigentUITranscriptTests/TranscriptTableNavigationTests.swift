#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The table transcript's keys and jumps: previous and next message, the keys that scroll it,
  /// Jump to top with its paging, and jumps that ease to where they go.
  @Suite("Transcript table navigation", .serialized)
  @MainActor
  struct TranscriptTableNavigationTests {
    static let width: CGFloat = 900
    static let height: CGFloat = 500
    let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    private var pagingActions: ConversationActions {
      var actions = ConversationActions()
      let log = self.log
      actions.loadOlder = { log.add("older") }
      return actions
    }

    func session(turns: Int = 8, hasMore: Bool = false) -> LiveConversation {
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: TranscriptFixture.turns(turns, startingAt: 10))
      state.hasMoreHistory = hasMore
      return LiveConversation(state)
    }

    private func screen(
      _ conversation: LiveConversation, actions: ConversationActions = ConversationActions()
    ) async throws -> (TranscriptScrollDriver, TranscriptTableController) {
      let window = transcriptScreen(
        TableTranscriptHost(conversation: conversation, actions: actions), width: Self.width,
        height: Self.height)
      try await letOpeningEnd(window)
      let driver = TranscriptScrollDriver(screen: window)
      return (driver, try #require(driver.tableController))
    }

    /// The row under the viewport's top.
    private func topRow(_ controller: TranscriptTableController) -> String? {
      controller.readingAnchor()?.id
    }

    func key(_ code: Int, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
      let characters = String(Character(try #require(Unicode.Scalar(code))))
      return try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: 0, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }

    @Test("Option-Command-Up and Down go a question at a time; Next at the last goes to the end")
    func messageKeys() async throws {
      let (driver, controller) = try await screen(session())
      let window = driver.screen
      defer { window.close() }
      // Opening framed the latest question at the top.
      #expect(topRow(controller) == "u17")
      try pressMessageKey(.previous, on: window)
      #expect(topRow(controller) == "u16")
      try pressMessageKey(.previous, on: window)
      #expect(topRow(controller) == "u15")
      #expect(!controller.follow.follows)
      try pressMessageKey(.next, on: window)
      #expect(topRow(controller) == "u16")
      try pressMessageKey(.next, on: window)
      try pressMessageKey(.next, on: window)
      #expect(abs(driver.offset - driver.maximumOffset) < 1)
      #expect(controller.follow.follows)
    }

    @Test("With one question the keys do nothing; with none above, Previous pages in more")
    func messageKeysAtTheEdges() async throws {
      let conversation = session(turns: 1, hasMore: true)
      let (driver, controller) = try await screen(conversation, actions: pagingActions)
      let window = driver.screen
      defer { window.close() }
      log.clear()
      try pressMessageKey(.previous, on: window)
      #expect(log.entries.isEmpty)
      conversation.append(contentsOf: TranscriptFixture.turns(1, startingAt: 11))
      try await letTasksRun(window)
      let scrollView = try #require(driver.scrollView)
      window.liveScroll(scrollView, began: true)
      controller.moveToTop()
      window.liveScroll(scrollView, began: false)
      log.clear()
      try pressMessageKey(.previous, on: window)
      #expect(log.entries == ["older"], "on screen \(controller.visibleRowIDs)")
      log.clear()
      controller.step(.previous)
      #expect(log.entries == ["older"], "on screen \(controller.visibleRowIDs)")
    }

    @Test("Keys a row passes on scroll a line, a page or to an end, as the reader's own scroll")
    func scrollingKeys() async throws {
      let (driver, controller) = try await screen(session(turns: 12))
      let window = driver.screen
      defer { window.close() }
      // Idle measuring gives the rows around the end their heights, so a step up moves by its
      // own length alone.
      window.run(for: TranscriptTableController.prefetchDelay + 0.5)
      driver.move(to: driver.maximumOffset - 1200)
      let line = TranscriptTableController.keyLine
      let page = controller.visibleHeight - line
      let steps: [(key: NSEvent, delta: CGFloat)] = [
        (try key(NSDownArrowFunctionKey), line), (try key(NSUpArrowFunctionKey), -line),
        (try key(NSPageDownFunctionKey), page), (try key(NSPageUpFunctionKey), -page),
        (try key(0x20), page), (try key(0x20, .shift), -page),
      ]
      for (event, delta) in steps {
        let start = driver.offset
        #expect(controller.scrolls(for: event))
        window.settle(0.05)
        #expect(abs(driver.offset - start - delta) < 1, "\(event): \(driver.offset - start)")
      }
      // A key the transcript does not scroll for goes on to the window.
      #expect(!controller.scrolls(for: try key(Int(Character("a").asciiValue ?? 0))))
      #expect(!controller.scrolls(for: try key(NSDownArrowFunctionKey, .command)))

      #expect(controller.scrolls(for: try key(NSHomeFunctionKey)))
      window.settle()
      #expect(abs(driver.offset - controller.minimumOffset) < 1)
      #expect(!controller.follow.follows)
      #expect(controller.scrolls(for: try key(NSEndFunctionKey)))
      // The reader's step ends once no other follows; at the end it follows again.
      window.run(for: TranscriptTableController.wheelEnd + 0.1)
      #expect(abs(driver.offset - driver.maximumOffset) < 1)
      #expect(controller.follow.follows)
    }

    @Test("A key a focused row does not use reaches the table, which scrolls")
    func keysReachTheTable() async throws {
      let (driver, controller) = try await screen(session(turns: 12))
      let window = driver.screen
      defer { window.close() }
      driver.move(to: 2000)
      restKeyboard(window)
      let start = driver.offset
      try window.press(keyCode: 121, characters: "\u{F72D}", modifiers: .function)
      // With nothing in the rows focused the window has the key, as it does over the stack.
      #expect(abs(driver.offset - start) < 1)
      controller.tableView.keyDown(with: try key(NSPageDownFunctionKey, .function))
      window.settle(0.05)
      #expect(driver.offset > start + 100)
    }

    @Test("Jump to top shows on pointing at the top and goes there")
    func jumpToTop() async throws {
      let (driver, controller) = try await screen(session())
      let window = driver.screen
      defer { window.close() }
      #expect(driver.offset > 100)
      let pill = CGPoint(x: Self.width / 2, y: 22)
      // Hidden until the pointer is at the top.
      try window.click(pill)
      #expect(driver.offset > 100)
      try window.hover(CGPoint(x: Self.width / 2, y: 40))
      try window.click(pill)
      #expect(await window.waitUntil { driver.offset <= controller.minimumOffset + 1 })
      #expect(!controller.follow.follows)
    }

    @Test("Scrolling up shows Jump to top, which then goes there")
    func jumpToTopOnScrollingUp() async throws {
      let (driver, controller) = try await screen(session())
      let window = driver.screen
      defer { window.close() }
      let scrollView = try #require(driver.scrollView)
      window.liveScroll(scrollView, began: true)
      for _ in 1...6 { driver.move(to: driver.offset - 20) }
      window.liveScroll(scrollView, began: false)
      try window.click(CGPoint(x: Self.width / 2, y: 22))
      #expect(await window.waitUntil { driver.offset <= controller.minimumOffset + 1 })
    }

    @Test("Jump to top pages in the rest of the history, then goes to its first row")
    func jumpToTopPages() async throws {
      let conversation = session(hasMore: true)
      let (driver, controller) = try await screen(conversation, actions: pagingActions)
      let window = driver.screen
      defer { window.close() }
      log.clear()
      controller.jumpToTop()
      #expect(log.entries == ["older"])
      #expect(controller.position.seeksTop)

      conversation.state.isLoadingHistory = true
      try await letTasksRun(window)
      conversation.state.rows.insert(contentsOf: TranscriptFixture.turns(2), at: 0)
      conversation.state.revision += 1
      conversation.state.isLoadingHistory = false
      try await letTasksRun(window)
      #expect(log.entries == ["older", "older"])
      #expect(driver.offset > 100, "the reader waits on their row while pages land")

      conversation.state.isLoadingHistory = true
      try await letTasksRun(window)
      conversation.state.rows.insert(contentsOf: TranscriptFixture.turns(2, startingAt: 2), at: 0)
      conversation.state.revision += 1
      conversation.state.hasMoreHistory = false
      conversation.state.isLoadingHistory = false
      #expect(
        await window.waitUntil { driver.offset <= controller.minimumOffset + 1 },
        "at \(driver.offset), on \(topRow(controller) ?? "no row")")
      #expect(log.entries.count == 2)
      #expect(!controller.position.seeksTop)
      // Idle measuring of the rows below leaves the reader at the top.
      window.run(for: TranscriptTableController.prefetchDelay + 0.3)
      #expect(driver.offset <= controller.minimumOffset + 1)
    }

    @Test("A page that brings nothing ends Jump to top at the top of what is loaded")
    func jumpToTopEmptyPage() async throws {
      let conversation = session(hasMore: true)
      let (driver, controller) = try await screen(conversation, actions: pagingActions)
      let window = driver.screen
      defer { window.close() }
      log.clear()
      controller.jumpToTop()
      conversation.state.isLoadingHistory = true
      try await letTasksRun(window)
      conversation.state.isLoadingHistory = false
      #expect(await window.waitUntil { driver.offset <= controller.minimumOffset + 1 })
      #expect(!controller.position.seeksTop)
    }

    @Test("With motion on a jump eases to where it goes, and the reader's scroll stops it")
    func animatedJumps() async throws {
      Theme.Motion.isEnabled = true
      defer { Theme.Motion.isEnabled = false }
      let (driver, controller) = try await screen(session())
      let window = driver.screen
      defer { window.close() }
      #expect(controller.animatesJumps)
      let start = driver.offset
      controller.show("u12", at: .top, animated: true)
      #expect(controller.activeJump != nil)
      #expect(abs(driver.offset - start) < 1, "a jump starts where the reader is")
      let target = try #require(controller.model.index(of: "u12"))
      #expect(
        await window.waitUntil {
          controller.activeJump == nil
            && abs(driver.offset - controller.tableView.rect(ofRow: target).minY) < 1
        })

      controller.jumpToLatest(animated: true)
      window.run(for: TranscriptTableJump.duration / 3)
      let midway = driver.offset
      #expect(midway > controller.tableView.rect(ofRow: target).minY + 1)
      #expect(midway < driver.maximumOffset - 1)
      controller.readerScrolled()
      #expect(controller.activeJump == nil)
      window.run(for: TranscriptTableJump.duration)
      #expect(abs(driver.offset - midway) < 1)
    }
  }
#endif
