#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  // Message links over live rows: the app's screen state has no rows, and the list reads them.
  extension TranscriptHistoryTests {
    /// The screen's state as the app builds it: no rows, which the list reads itself.
    private func rowlessSession(hasMore: Bool) -> LiveConversation {
      var state = ConversationViewState(header: TranscriptFixture.header)
      state.hasMoreHistory = hasMore
      return LiveConversation(state)
    }

    /// A focus with a link to `messageID` waiting.
    private func link(to messageID: String) -> TranscriptFocus {
      let focus = TranscriptFocus()
      focus.focus(messageID, in: TranscriptFixture.header.id)
      return focus
    }

    /// A read of older history as the store reports it: the page reaches the rows read as the
    /// read ends, before the list shows it.
    private func readPage(
      _ page: [Row], into source: LiveRowsSource, of conversation: LiveConversation,
      hasMore: Bool, on window: OffscreenWindow<AnyView>
    ) async throws {
      conversation.state.isLoadingHistory = true
      try await letTasksRun(window)
      source.prepend(page)
      conversation.state.hasMoreHistory = hasMore
      conversation.state.isLoadingHistory = false
      conversation.state.historyReads += 1
    }

    @Test("Over live rows, a link finds its message in the rows the list shows")
    func liveMessageLink() async throws {
      let focus = link(to: "u11")
      let source = LiveRowsSource(TranscriptFixture.turns(6, startingAt: 10))
      let (window, viewport) = try await screen(
        rowlessSession(hasMore: false), rows: source, focus: focus)
      defer { window.close() }
      #expect(await window.waitUntil { focus.flashedRowID == "u11" })
      #expect(focus.messageID(in: TranscriptFixture.header.id) == nil)
      #expect(viewport.fractionRead < 0.5, "the second of six turns is in view, not the latest")
    }

    @Test("Over live rows, a link to an older message reads pages until the list shows it")
    func liveMessageLinkPages() async throws {
      let focus = link(to: "u1")
      let conversation = rowlessSession(hasMore: true)
      let source = LiveRowsSource(TranscriptFixture.turns(6, startingAt: 10))
      let (window, viewport) = try await screen(
        conversation, rows: source, actions: pagingActions, focus: focus)
      defer { window.close() }
      #expect(await window.waitUntil { log.entries == ["older"] })
      try await readPage(
        TranscriptFixture.turns(2, startingAt: 4), into: source, of: conversation, hasMore: true,
        on: window)
      #expect(await window.waitUntil { log.entries == ["older", "older"] })
      #expect(focus.messageID(in: TranscriptFixture.header.id) == "u1")

      try await readPage(
        TranscriptFixture.turns(2), into: source, of: conversation, hasMore: false, on: window)
      #expect(await window.waitUntil { focus.flashedRowID == "u1" })
      #expect(focus.messageID(in: TranscriptFixture.header.id) == nil)
      #expect(log.entries.count == 2)
      #expect(viewport.fractionRead < 0.5, "the oldest page's second turn is in view")
    }

    @Test("Over live rows, a link to a message that doesn't exist reads to the first, then stops")
    func liveMessageLinkMissing() async throws {
      let focus = link(to: "gone")
      let conversation = rowlessSession(hasMore: true)
      let source = LiveRowsSource(TranscriptFixture.turns(6, startingAt: 10))
      let (window, _) = try await screen(
        conversation, rows: source, actions: pagingActions, focus: focus)
      defer { window.close() }
      #expect(await window.waitUntil { log.entries == ["older"] })
      try await readPage(
        TranscriptFixture.turns(2), into: source, of: conversation, hasMore: false, on: window)
      #expect(
        await window.waitUntil { focus.messageID(in: TranscriptFixture.header.id) == nil })
      try await letTasksRun(window, milliseconds: 200)
      #expect(focus.flashedRowID == nil)
      #expect(log.entries == ["older"])
    }

    @Test("Over live rows, a link stops reading when a read it asked for adds nothing")
    func liveMessageLinkFailedRead() async throws {
      let focus = link(to: "u1")
      let conversation = rowlessSession(hasMore: true)
      let source = LiveRowsSource(TranscriptFixture.turns(6, startingAt: 10))
      let (window, _) = try await screen(
        conversation, rows: source, actions: pagingActions, focus: focus)
      defer { window.close() }
      #expect(await window.waitUntil { log.entries == ["older"] })
      // The read fails: it ends with no rows, and more history remains.
      conversation.state.isLoadingHistory = true
      try await letTasksRun(window)
      conversation.state.isLoadingHistory = false
      conversation.state.historyReads += 1
      #expect(
        await window.waitUntil { focus.messageID(in: TranscriptFixture.header.id) == nil })
      try await letTasksRun(window, milliseconds: 200)
      #expect(log.entries == ["older"])
    }
  }
#endif
