#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  // Message links over live rows: the app's screen state has no rows, and the list reads them.
  extension TranscriptHistoryTests {
    @Test("Over live rows, a link finds its message in the rows the list shows")
    func liveMessageLink() async throws {
      let focus = TranscriptFocus.linking(to: "u11")
      let source = LiveRowsSource(TranscriptFixture.turns(6, startingAt: 10))
      let (window, viewport) = try await screen(
        LiveConversation.rowless(hasMore: false), rows: source, focus: focus)
      defer { window.close() }
      #expect(await window.waitUntil { focus.flashedRowID == "u11" })
      #expect(focus.messageID(in: TranscriptFixture.header.id) == nil)
      #expect(viewport.fractionRead < 0.5, "the second of six turns is in view, not the latest")
    }

    @Test("Over live rows, a link to an older message reads pages until the list shows it")
    func liveMessageLinkPages() async throws {
      let focus = TranscriptFocus.linking(to: "u1")
      let conversation = LiveConversation.rowless(hasMore: true)
      let source = LiveRowsSource(TranscriptFixture.turns(6, startingAt: 10))
      let (window, viewport) = try await screen(
        conversation, rows: source, actions: pagingActions, focus: focus)
      defer { window.close() }
      #expect(await window.waitUntil { log.entries == ["older"] })
      try await source.readPage(
        TranscriptFixture.turns(2, startingAt: 4), of: conversation, hasMore: true, on: window)
      #expect(await window.waitUntil { log.entries == ["older", "older"] })
      #expect(focus.messageID(in: TranscriptFixture.header.id) == "u1")

      try await source.readPage(
        TranscriptFixture.turns(2), of: conversation, hasMore: false, on: window)
      #expect(await window.waitUntil { focus.flashedRowID == "u1" })
      #expect(focus.messageID(in: TranscriptFixture.header.id) == nil)
      #expect(log.entries.count == 2)
      #expect(viewport.fractionRead < 0.5, "the oldest page's second turn is in view")
    }

    @Test("Over live rows, a link to a message that doesn't exist reads to the first, then stops")
    func liveMessageLinkMissing() async throws {
      let focus = TranscriptFocus.linking(to: "gone")
      let conversation = LiveConversation.rowless(hasMore: true)
      let source = LiveRowsSource(TranscriptFixture.turns(6, startingAt: 10))
      let (window, _) = try await screen(
        conversation, rows: source, actions: pagingActions, focus: focus)
      defer { window.close() }
      #expect(await window.waitUntil { log.entries == ["older"] })
      try await source.readPage(
        TranscriptFixture.turns(2), of: conversation, hasMore: false, on: window)
      #expect(
        await window.waitUntil { focus.messageID(in: TranscriptFixture.header.id) == nil })
      try await letTasksRun(window, milliseconds: 200)
      #expect(focus.flashedRowID == nil)
      #expect(log.entries == ["older"])
    }

    @Test("Over live rows, a link stops reading when a read it asked for adds nothing")
    func liveMessageLinkFailedRead() async throws {
      let focus = TranscriptFocus.linking(to: "u1")
      let conversation = LiveConversation.rowless(hasMore: true)
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
