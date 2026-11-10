#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import SwiftUI

  @testable import OmnigentUIComponents

  /// The width of the pane a transcript sits in, which a test changes as a resize does.
  @MainActor
  @Observable
  final class PaneWidth {
    var value: CGFloat

    init(_ value: CGFloat) {
      self.value = value
    }
  }

  /// The transcript in a pane whose width changes under it.
  struct ResizedTranscriptHost: View {
    let conversation: LiveConversation
    let width: PaneWidth
    var actions = ConversationActions()
    /// Runs when the transcript's scroll view comes to its top, inside that layout pass.
    var atTop: @MainActor () -> Void = {}

    var body: some View {
      LiveTranscriptHost(conversation: conversation, actions: actions)
        .onScrollGeometryChange(for: Bool.self) { geometry in
          geometry.contentOffset.y <= ScrollEdgeWatch.reach
        } action: { _, isAtTop in
          if isAtTop { atTop() }
        }
        .frame(width: width.value)
    }
  }

  /// What the transcript's scroll view held when a frame was committed.
  struct CommittedFrame: Equatable {
    /// A selectable text in view and its frame in the scrolled content.
    struct Line: Equatable {
      var text: String
      var frame: CGRect
    }

    /// The part of the content in view.
    var viewport: CGRect
    /// The viewport's bottom that the content keeps clear, as under the message navigator.
    var bottomInset: CGFloat
    var lines: [Line]
    /// The scroll view clips what it scrolls to its own bounds, the pane's.
    var clips: Bool

    /// Points scrolled below the top of the content.
    var offset: CGFloat { viewport.minY }

    /// The middle of what the reader sees, where the reading anchor is taken.
    var middle: CGFloat { viewport.minY + (viewport.height - bottomInset) / 2 }

    /// From the leading edge of the answers' text to the trailing edge of the questions': the
    /// rows' width less their own padding. `nil` with no text in view.
    var textSpan: CGFloat? {
      guard let leading = lines.map(\.frame.minX).min(), let trailing = trailingEdge else {
        return nil
      }
      return trailing - leading
    }

    /// The trailing edge of the text furthest that way, in the viewport's own coordinates.
    var trailingEdge: CGFloat? { lines.map(\.frame.maxX).max() }

    /// The text nearest the reader's middle.
    var lineAtMiddle: Line? {
      lines.min { abs($0.frame.midY - middle) < abs($1.frame.midY - middle) }
    }

    /// How far below the reader's middle the text `text` is; `nil` when it is not in view.
    func distanceBelowMiddle(of text: String) -> CGFloat? {
      lines.first { $0.text == text }.map { $0.frame.midY - middle }
    }
  }

  /// Records the transcript at each frame Core Animation commits. It commits its transaction
  /// from a main run loop observer of order 2 000 000, before the loop waits or exits, with
  /// AppKit's layout and SwiftUI's update inside it; an observer after that one reads what the
  /// frame went out with, whatever a layout pass passed through on the way.
  @MainActor
  final class CommittedFrames {
    /// After Core Animation's own observer.
    private static let order: CFIndex = 2_500_000

    private let scrollView: NSScrollView
    /// The frame before anything recorded.
    let settled: CommittedFrame
    private var frames: [CommittedFrame] = []

    init(_ screen: OffscreenWindow<AnyView>) throws {
      guard let scrollView = TranscriptScrollDriver(screen: screen).scrollView else {
        throw OffscreenWindowError.notFound("transcript scroll view")
      }
      self.scrollView = scrollView
      settled = Self.read(scrollView)
    }

    /// The frames committed while `drive` runs, each once however many loops it stayed for.
    func recording(_ drive: () throws -> Void) rethrows -> [CommittedFrame] {
      frames = []
      // A loop that `RunLoop.run(until:)` ends after one source exits without waiting.
      let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
      let observer = CFRunLoopObserverCreateWithHandler(
        nil, activities, true, Self.order
      ) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.committed() }
      }
      CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
      defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
      try drive()
      return frames
    }

    private func committed() {
      let frame = Self.read(scrollView)
      if frame != frames.last ?? settled { frames.append(frame) }
    }

    /// The scroll view as it is now. Rows that left the viewport can keep their views, so only
    /// texts within it count.
    private static func read(_ scrollView: NSScrollView) -> CommittedFrame {
      let viewport = scrollView.contentView.bounds
      var lines: [CommittedFrame.Line] = []
      var unvisited = scrollView.documentView.map { [$0] } ?? []
      while let view = unvisited.popLast() {
        unvisited.append(contentsOf: view.subviews)
        guard let field = view as? NSTextField else { continue }
        let frame = field.convert(field.bounds, to: scrollView.documentView)
        if frame.intersects(viewport) {
          lines.append(CommittedFrame.Line(text: field.stringValue, frame: frame))
        }
      }
      lines.sort { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
      return CommittedFrame(
        viewport: viewport, bottomInset: scrollView.contentInsets.bottom, lines: lines,
        clips: scrollView.contentView.clipsToBounds)
    }
  }

  // An expectation on a frame would otherwise print every text in view.
  extension CommittedFrame: CustomReflectable {
    var customMirror: Mirror { Mirror(reflecting: "frame at \(offset), \(viewport.width) wide") }
  }

  /// Lets the main run loop commit frames for `seconds`, with no layout forced from outside: a
  /// width set before it is laid out in the display cycle, as the app's is.
  @MainActor
  func commitFrames(for seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
  }
#endif
