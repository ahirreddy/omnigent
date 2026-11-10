#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The transcript's timers, reading anchor and following on the paths a session rarely takes.
  @Suite("Transcript edges", .serialized)
  @MainActor
  struct TranscriptGapsTests {
    @Observable
    final class RowStore {
      var rows: [Row] = []
      var revision: UInt64 = 0

      func append(_ text: String) {
        rows.append(Row(id: "r\(rows.count)", role: .assistant, text: text))
        revision += 1
      }
    }

    private func reader(_ store: RowStore) -> LiveTranscriptRows {
      LiveTranscriptRows { (store.rows, store.revision) }
    }

    private func spin(until condition: () -> Bool) async throws {
      for _ in 0..<500 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
      }
    }

    @Test("An update timed for a transcript that was hidden meanwhile waits until it shows")
    func pacerHiddenBeforeTick() async throws {
      let store = RowStore()
      let pacer = TranscriptRowsPacer(interval: .milliseconds(30))
      _ = pacer.rows(from: reader(store))
      store.append("first")
      try await spin { pacer.published == 1 }
      _ = pacer.rows(from: reader(store))
      store.append("second")
      try await Task.sleep(for: .milliseconds(5))
      pacer.setShown(false)
      try await Task.sleep(for: .milliseconds(60))
      #expect(pacer.published == 1, "nothing publishes to a hidden transcript")
      pacer.setShown(true)
      try await spin { pacer.published == 2 }
      #expect(pacer.published == 2)
      #expect(pacer.rows(from: reader(store)).rows.count == 2)
    }

    @Test("A newer schedule replaces an update still waiting for its tick")
    func pacerRescheduled() async throws {
      let store = RowStore()
      let pacer = TranscriptRowsPacer(interval: .seconds(30))
      _ = pacer.rows(from: reader(store))
      pacer.schedule(after: .seconds(30))
      try await Task.sleep(for: .milliseconds(10))
      pacer.schedule(after: .zero)
      try await spin { pacer.published == 1 }
      #expect(pacer.published == 1, "published without waiting 30 seconds")
    }

    @Test("A reply's preview skips empty and non-assistant messages until a reply has text")
    func responsePreview() {
      func entry(_ id: String, _ role: RowRole, _ text: String) -> SegmentEntry {
        SegmentEntry(
          segment: .item(.message(Row(id: id, role: role, text: text))), decorations: [:],
          duration: nil)
      }
      let entries = [
        entry("u", .user, "Hi"), entry("blank", .assistant, "  \n"), entry("tool", .tool, "note"),
        entry("a", .assistant, " Hello "),
      ]
      #expect(TurnRailModel.responsePreview(after: "u", in: entries) == "Hello")
      #expect(TurnRailModel.responsePreview(after: "u", in: Array(entries.prefix(3))).isEmpty)
      #expect(TurnRailModel.responsePreview(after: "gone", in: entries).isEmpty)
    }

    @Test("A flash ends on its own, and a newer flash keeps its full time")
    func flashTimers() async throws {
      let focus = TranscriptFocus()
      focus.flashDuration = .milliseconds(30)
      focus.flash("one")
      #expect(focus.flashedRowID == "one")
      try await spin { focus.flashedRowID == nil }
      #expect(focus.flashedRowID == nil)
      focus.flash("two")
      focus.flashDuration = .seconds(60)
      focus.flash("three")
      try await Task.sleep(for: .milliseconds(80))
      #expect(focus.flashedRowID == "three", "the replaced flash's timer doesn't end this one")
    }

    @Test("A link replaced before the transcript scrolled only shows the newer message")
    func replacedLink() async throws {
      let focus = TranscriptFocus()
      let id = TranscriptFixture.header.id
      let state = ConversationViewState(header: TranscriptFixture.header)
      var shown: [String] = []
      let screen = OffscreenWindow(
        Color.clear
          .modifier(
            TranscriptMessageFocus(
              state: state, pages: false, locate: { $0 }, loadOlder: {}, show: { shown.append($0) })
          )
          .environment(\.transcriptFocus, focus), width: 100, height: 100)
      defer { screen.close() }
      focus.focus("old", in: id)
      try await screen.letTasksRun(passes: 1)
      focus.focus("new", in: id)
      try await spin { !shown.isEmpty }
      #expect(shown == ["new"])
    }

    @Test("A folded reasoning row names how long it thought, once the stream ends")
    func reasoningDuration() throws {
      let streaming = EditedValue(true)
      struct Host: View {
        let streaming: EditedValue<Bool>
        var body: some View {
          ReasoningRowView(
            row: TranscriptFixture.activityRow(.reasoning, isStreaming: streaming.value),
            activity: Activity(kind: .reasoning, title: "Thinking", summary: ""))
        }
      }
      let screen = OffscreenWindow(Host(streaming: streaming), width: 500, height: 200)
      defer { screen.close() }
      #expect(try screen.shows("Thinking\u{2026}"))
      streaming.value = false
      screen.settle(0.1)
      #expect(try screen.shows("Thought for 0"))
      #expect(try !screen.shows("a few seconds"))
    }

    @Test("A whitespace selection offers nothing")
    func blankSelection() async throws {
      let log = HostLog()
      let screen = transcriptScreen(
        Text("     ").textSelection(.enabled).padding(.top, 60).padding(.leading, 20)
          .frame(maxWidth: .infinity, alignment: .leading)
          .transcriptSelectionPopup(reply: { log.add($0) }, ask: nil))
      defer { screen.close() }
      try screen.click(CGPoint(x: 30, y: 67), clickCount: 3)
      let editor = screen.window.firstResponder as? NSTextView
      editor?.selectAll(nil)
      try await announceSelection(screen)
      #expect(try !screen.shows("Reply"))
    }

    @Test("A text view with no layout has no selection bounds")
    func selectionWithoutLayout() {
      let watcher = SelectionWatcher.WatcherView()
      let unlaidOut = NSTextView(frame: .zero, textContainer: NSTextContainer())
      #expect(watcher.bounds(of: NSRange(location: 0, length: 1), in: unlaidOut) == nil)
    }

    @Test("Output that arrives during a scroll waits, and catches up when the scroll ends")
    func catchesUpAfterScroll() async throws {
      let rows = (0..<10).flatMap { index in
        [TranscriptFixture.user("u\(index)"), TranscriptFixture.answer("a\(index)")]
      }
      let conversation = LiveConversation(
        ConversationViewState(header: TranscriptFixture.header, rows: rows))
      let screen = transcriptScreen(
        LiveTranscriptHost(conversation: conversation, actions: ConversationActions()),
        width: 500, height: 300)
      defer { screen.close() }
      // Past the opening's framing wait, so the transcript follows.
      try await letTasksRun(screen, milliseconds: 700)
      let driver = TranscriptScrollDriver(screen: screen)
      let scroll = try #require(driver.scrollView)
      let reading = driver.offset
      screen.liveScroll(scroll, began: true)
      conversation.append(TranscriptFixture.answer("late", "One more line"))
      try await letTasksRun(screen, milliseconds: 200)
      #expect(driver.offset == reading, "nothing moves under the reader's finger")
      screen.liveScroll(scroll, began: false)
      #expect(try await waitUntil(screen) { driver.offset > reading + 10 })
    }
  }
#endif
