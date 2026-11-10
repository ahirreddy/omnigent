#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
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

    /// Adds rows at the end, with a new revision.
    func append(_ rows: Row...) {
      append(contentsOf: rows)
    }

    /// Adds rows at the end, with a new revision.
    func append(contentsOf rows: [Row]) {
      state.rows.append(contentsOf: rows)
      state.revision += 1
    }
  }

  /// The transcript over a ``LiveConversation``.
  struct LiveTranscriptHost: View {
    let conversation: LiveConversation
    let actions: ConversationActions

    var body: some View {
      TranscriptView(
        state: conversation.state, actions: actions,
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

  /// The message navigator's Previous and Next, at the transcript's bottom-trailing corner.
  @MainActor
  func navigatorButtons(on window: OffscreenWindow<AnyView>, width: CGFloat) -> [CGRect] {
    window.controlFrames.filter { $0.maxX > width - 40 && $0.minY > 300 }
      .sorted { $0.minY < $1.minY }
  }

  // An expectation on the driver would otherwise print the whole window's view tree.
  extension TranscriptScrollDriver: CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(reflecting: "transcript scroll driver") }
  }

  extension TranscriptFixture {
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
