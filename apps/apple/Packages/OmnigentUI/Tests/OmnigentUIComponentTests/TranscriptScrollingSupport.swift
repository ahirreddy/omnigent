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

    /// How far the reader is from the real end. Lazy rows above the viewport only estimate the
    /// content's height, so this goes to the end, where the estimate settles, and comes back.
    func distanceToEnd() -> CGFloat {
      let reading = offset
      for _ in 0..<3 { move(to: maximumOffset) }
      let distance = offset - reading
      move(to: reading)
      return distance
    }

    /// Scrolls as a reader does: a live scroll begins, moves in steps, and ends.
    /// - Parameter delta: Points to move; negative is up.
    func readerScroll(by delta: CGFloat) {
      guard let scrollView else { return }
      let center = NotificationCenter.default
      center.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
      screen.settle(0.02)
      let start = offset
      let steps = 6
      for step in 1...steps {
        move(to: start + delta * CGFloat(step) / CGFloat(steps))
        center.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
      }
      center.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
      screen.settle()
    }

    /// Moves the position with no gesture, as a layout pass does.
    func move(to offset: CGFloat) {
      guard let scrollView else { return }
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
      scrollView.reflectScrolledClipView(scrollView.contentView)
      screen.settle()
    }
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
