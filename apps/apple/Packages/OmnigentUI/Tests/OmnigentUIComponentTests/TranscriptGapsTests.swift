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
      _ = pacer.rows(from: reader(store), isShown: true)
      store.append("first")
      try await spin { pacer.published == 1 }
      _ = pacer.rows(from: reader(store), isShown: true)
      store.append("second")
      try await Task.sleep(for: .milliseconds(5))
      _ = pacer.rows(from: reader(store), isShown: false)
      try await Task.sleep(for: .milliseconds(60))
      #expect(pacer.published == 1, "nothing publishes to a hidden transcript")
      _ = pacer.rows(from: reader(store), isShown: true)
      try await spin { pacer.published == 2 }
      #expect(pacer.published == 2)
      #expect(pacer.rows(from: reader(store), isShown: true).rows.count == 2)
    }

    @Test("A newer schedule replaces an update still waiting for its tick")
    func pacerRescheduled() async throws {
      let store = RowStore()
      let pacer = TranscriptRowsPacer(interval: .seconds(30))
      _ = pacer.rows(from: reader(store), isShown: true)
      pacer.schedule(after: .seconds(30))
      try await Task.sleep(for: .milliseconds(10))
      pacer.schedule(after: .zero)
      try await spin { pacer.published == 1 }
      #expect(pacer.published == 1, "published without waiting 30 seconds")
    }

    private func anchor(id: String, width: CGFloat) -> TranscriptReadingAnchor {
      TranscriptReadingAnchor(
        id: id, fraction: 0.25, rowHeight: 100, viewportWidth: width, viewportHeight: 300)
    }

    @Test("Back at a width whose row height is known, the row goes straight to its place")
    func restoreAtKnownWidth() {
      let scroll = TranscriptScrollState()
      var scrolled: [String] = []
      scroll.scrollToRow = { id, point in scrolled.append("\(id) \(point.y)") }
      let sample = anchor(id: "row", width: 400)
      scroll.record(sample)
      scroll.restoreReading(from: 400, to: 400)
      #expect(scrolled == ["row \(sample.unitPoint(in: sample).y)"])
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

    @Test("Output that arrived during a scroll catches up when it ends at the bottom")
    func catchesUpAfterScroll() async throws {
      let conversation = LiveConversation(
        ConversationViewState(
          header: TranscriptFixture.header, rows: TranscriptFixture.turns(6, startingAt: 10)))
      let screen = transcriptScreen(
        LiveTranscriptHost(conversation: conversation, actions: ConversationActions()),
        width: 500, height: 300)
      defer { screen.close() }
      try await letTasksRun(screen, milliseconds: 200)
      let driver = TranscriptScrollDriver(screen: screen)
      let scroll = try #require(driver.scrollView)
      screen.liveScroll(scroll, began: true)
      conversation.append(contentsOf: TranscriptFixture.turns(3, startingAt: 40))
      try await letTasksRun(screen, milliseconds: 200)
      screen.liveScroll(scroll, began: false)
      #expect(try await waitUntil(screen) { driver.maximumOffset - driver.offset < 2 })
    }
  }
#endif
