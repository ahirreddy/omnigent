#if os(macOS) || os(iOS)
  import Observation
  import SwiftUI

  @testable import OmnigentUIComponents

  /// A conversation a test changes from outside, as the store does while a session runs.
  @MainActor
  @Observable
  final class LiveConversation {
    var state: ConversationViewState
    var scrollRequest = 0

    init(_ state: ConversationViewState) {
      self.state = state
    }

    /// The screen's state as the app builds it: no rows, which the list reads itself.
    static func rowless(hasMore: Bool) -> LiveConversation {
      var state = ConversationViewState(header: TranscriptFixture.header)
      state.hasMoreHistory = hasMore
      return LiveConversation(state)
    }

    /// Adds rows at the end, with a new revision.
    func append(_ rows: Row...) {
      append(contentsOf: rows)
    }

    /// Adds rows at the end, with a new revision.
    func append(contentsOf rows: [Row]) {
      state.rows.append(contentsOf: rows)
      state.revision += 1
    }

    /// Sends a message from here, as the store does: the send is counted and its row shows.
    func send(_ row: Row) {
      state.sendCount += 1
      append(row)
    }

    /// The server's echo takes the place of the row a send showed.
    func echo(_ sentID: String, as row: Row) {
      state.rows.removeAll { $0.id == sentID }
      append(row)
    }

    /// The streaming reply `id` now reads `text`; its row is added the first time.
    func stream(_ id: String, _ text: String) {
      var reply = TranscriptFixture.answer(id, text, responseID: id)
      reply.isStreaming = true
      state.rows.removeAll { $0.id == id }
      append(reply)
    }
  }
#endif

#if os(macOS)
  import AppKit
  import OmnigentViewTesting

  /// Rows a transcript's list reads itself, kept apart from the screen's state as the app's store
  /// keeps them.
  @MainActor
  @Observable
  final class LiveRowsSource {
    private(set) var rows: [Row]
    private(set) var revision: UInt64 = 1

    init(_ rows: [Row]) {
      self.rows = rows
    }

    var reader: LiveTranscriptRows {
      LiveTranscriptRows { (rows: self.rows, revision: self.revision) }
    }

    /// Puts a page of older rows above, with a new revision.
    func prepend(_ page: [Row]) {
      rows.insert(contentsOf: page, at: 0)
      revision += 1
    }

    /// A read of older history as the store reports it: the page reaches the rows read as the
    /// read ends, before the list shows it.
    func readPage(
      _ page: [Row], of conversation: LiveConversation, hasMore: Bool,
      on window: OffscreenWindow<AnyView>
    ) async throws {
      conversation.state.isLoadingHistory = true
      try await letTasksRun(window)
      prepend(page)
      conversation.state.hasMoreHistory = hasMore
      conversation.state.isLoadingHistory = false
      conversation.state.historyReads += 1
    }
  }

  extension TranscriptFocus {
    /// A focus with a `?message=` link to `messageID` in the fixture's session waiting.
    static func linking(to messageID: String) -> TranscriptFocus {
      let focus = TranscriptFocus()
      focus.focus(messageID, in: TranscriptFixture.header.id)
      return focus
    }
  }

  /// The transcript over a ``LiveConversation``. With `rows`, the list reads its rows from them
  /// and not from the conversation's state, as the app's does.
  struct LiveTranscriptHost: View {
    let conversation: LiveConversation
    let actions: ConversationActions
    var rows: LiveTranscriptRows?

    var body: some View {
      TranscriptView(
        state: conversation.state, liveRows: rows, actions: actions,
        scrollToLatestRequest: conversation.scrollRequest)
    }
  }

  /// The table transcript over a ``LiveConversation``, whatever list the app picks.
  struct TableTranscriptHost: View {
    let conversation: LiveConversation
    let actions: ConversationActions

    var body: some View {
      TableTranscriptView(
        state: conversation.state, liveRows: nil, actions: actions,
        scrollToLatestRequest: conversation.scrollRequest)
    }
  }

  /// The pane a transcript sits in: its width and the dock under it, which a test changes as a
  /// resize and a growing composer do.
  @MainActor
  @Observable
  final class TranscriptPane {
    var width: CGFloat
    var dock: CGFloat

    init(width: CGFloat, dock: CGFloat) {
      self.width = width
      self.dock = dock
    }
  }

  /// The transcript over a dock that insets it, as the conversation screen lays it out.
  struct DockedTranscriptHost: View {
    let conversation: LiveConversation
    let pane: TranscriptPane

    var body: some View {
      LiveTranscriptHost(conversation: conversation, actions: ConversationActions())
        .safeAreaBar(edge: .bottom, spacing: 0) { Color.clear.frame(height: pane.dock) }
        .frame(width: pane.width)
    }
  }

  /// Reads and moves a hosted transcript's scroll position.
  @MainActor
  struct TranscriptScrollDriver {
    let screen: OffscreenWindow<AnyView>

    /// The transcript's scroll view: the tallest one, as the turn rail has its own.
    var scrollView: NSScrollView? {
      screen.allViews.compactMap { $0 as? NSScrollView }.max { $0.frame.height < $1.frame.height }
    }

    /// Points scrolled below the top of the content.
    var offset: CGFloat { scrollView?.contentView.bounds.minY ?? 0 }

    /// How far the content can scroll.
    var maximumOffset: CGFloat {
      guard let scrollView, let document = scrollView.documentView else { return 0 }
      // The table transcript's bars inset its scroll view, not its rows, so it can scroll past
      // them; its controller knows how far.
      if let table = document as? NSTableView,
        let controller = table.delegate as? TranscriptTableController
      {
        return controller.maximumOffset
      }
      return max(0, document.frame.height - scrollView.contentView.bounds.height)
    }

    /// How far through the content the middle of the viewport is, from 0 to 1.
    var fractionRead: CGFloat {
      guard let scrollView else { return 0 }
      let viewport = scrollView.contentView.bounds.height
      return (offset + viewport / 2) / (maximumOffset + viewport)
    }

    /// How far the reader is from the real end. Lazy rows above the viewport only estimate the
    /// content's height, so this goes to the end, where the estimate settles, and comes back.
    func distanceToEnd() -> CGFloat {
      let reading = offset
      for _ in 0..<3 { move(to: maximumOffset) }
      let distance = offset - reading
      move(to: reading)
      return distance
    }

    /// The table transcript's controller, when the window shows the table.
    var tableController: TranscriptTableController? {
      (scrollView?.documentView as? NSTableView)?.delegate as? TranscriptTableController
    }

    /// Where the reader is: in the table, the row under the viewport's top and how far into it,
    /// as rows measured above it while the reader is still move the offset and not what they
    /// see; in the stack, the offset.
    struct ReaderPlace {
      var row: String?
      var offset: CGFloat
    }

    var readerPlace: ReaderPlace {
      if let anchor = tableController?.readingAnchor() {
        return ReaderPlace(row: anchor.id, offset: anchor.offset)
      }
      return ReaderPlace(row: nil, offset: offset)
    }

    /// How far what the reader sees moved since they were at `place`.
    func distance(from place: ReaderPlace) -> CGFloat {
      guard let row = place.row, let controller = tableController else {
        return abs(offset - place.offset)
      }
      guard let index = controller.model.index(of: row) else { return .infinity }
      let top = controller.clipView.bounds.minY + controller.insets.top
      return abs(top - (controller.tableView.rect(ofRow: index).minY + place.offset))
    }

    /// Moves the position with no gesture, as a layout pass does.
    func move(to offset: CGFloat) {
      guard let scrollView else { return }
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
      scrollView.reflectScrolledClipView(scrollView.contentView)
      screen.settle()
    }
  }

  /// Keeps a run loop source firing on the main thread, as a stream of events or callbacks does.
  /// A loop that handled a source skips its before-waiting observers, so SwiftUI's next update
  /// waits while the main queue keeps draining.
  @MainActor
  final class BusyMainRunLoop: NSObject {
    private var isRunning = false

    func start() {
      isRunning = true
      requeue()
    }

    func stop() {
      isRunning = false
    }

    private func requeue() {
      perform(#selector(fire), on: .main, with: nil, waitUntilDone: false)
    }

    @objc private func fire() {
      if isRunning { requeue() }
    }
  }

  /// Presses the Mac's key for the previous or next user message: Option-Command-Up or -Down.
  @MainActor
  func pressMessageKey(
    _ direction: TranscriptNavigation.Direction, on window: OffscreenWindow<AnyView>
  ) throws {
    let (keyCode, arrow): (UInt16, String) =
      direction == .previous ? (126, "\u{F700}") : (125, "\u{F701}")
    try window.press(
      keyCode: keyCode, characters: arrow, modifiers: [.command, .option, .numericPad])
    // The jump is an animated scroll: it gets the time a click's own settling gives one.
    window.settle()
  }

  // An expectation on the driver would otherwise print the whole window's view tree.
  extension TranscriptScrollDriver: CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(reflecting: "transcript scroll driver") }
  }
#endif

#if os(macOS) || os(iOS)
  extension TranscriptFixture {
    /// A message being sent: shown before the server has it, so with no author yet.
    static func sending(_ id: String, _ text: String) -> Row {
      var row = user(id, text)
      row.isEphemeral = true
      return row
    }

    /// `count` turns of a question and an answer long enough that a few fill the window.
    static func turns(_ count: Int, startingAt first: Int = 0) -> [Row] {
      (first..<(first + count)).flatMap { index in
        [
          user("u\(index)", "Question \(index)"),
          answer(
            "a\(index)",
            (0..<12).map { "Line \($0) of answer \(index)" }.joined(separator: "\n\n"),
            responseID: "r\(index)"),
        ]
      }
    }
  }
#endif
