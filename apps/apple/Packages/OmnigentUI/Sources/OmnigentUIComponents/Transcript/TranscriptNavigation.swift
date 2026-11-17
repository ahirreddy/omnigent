import SwiftUI

/// Where previous and next user message go, from the rows on screen (web `UserMessageNav`).
nonisolated enum TranscriptNavigation {
  /// A direction to move.
  enum Direction {
    /// The user message above the top of the screen.
    case previous
    /// The user message below the top of the screen.
    case next
  }

  /// The user message to move to.
  /// - Parameters:
  ///   - direction: Up or down.
  ///   - order: Every rendered segment id, top to bottom.
  ///   - userMessages: The ids in `order` that are user messages.
  ///   - visible: The ids on screen, in any order.
  /// - Returns: The target id, or `nil` when there is none in that direction.
  static func target(
    _ direction: Direction, order: [String], userMessages: Set<String>, visible: Set<String>
  ) -> String? {
    let top = order.firstIndex { visible.contains($0) }
    let users = order.indices.filter { userMessages.contains(order[$0]) }
    switch direction {
    case .previous:
      guard let top else { return users.last.map { order[$0] } }
      return users.last { $0 < top }.map { order[$0] }
    case .next:
      guard let top else { return nil }
      return users.first { $0 > top }.map { order[$0] }
    }
  }

  /// The segment ids that are user messages.
  static func userMessages(_ entries: [SegmentEntry]) -> Set<String> {
    Set(
      entries.compactMap { entry in
        if case .item(.message(let row)) = entry.segment, row.role == .user { return entry.id }
        return nil
      })
  }
}

/// Where the reads of older history stand, for the transcript to act when one ends.
struct HistoryRead: Equatable {
  var isLoading: Bool
  /// How many reads ended so far.
  var ended: Int
}

/// Scroll facts the transcript acts on but never renders, so updating them on every scroll does
/// not re-render the rows.
@MainActor
final class TranscriptReadingPosition {
  /// The segment ids on screen.
  var visible: Set<String> = []
  /// The top segment when older history was requested; it is put back at the top once the
  /// older rows land above it.
  var prependAnchor: String?
  /// Older history was requested and its rows have not landed yet.
  var awaitsPage = false
  /// Jump to top is paging in the rest of the history first.
  var seeksTop = false
  /// The first loaded row when older history was requested, to tell whether the page added any.
  var topBeforePage: String?
  /// Jump to top has read all it can, and goes to the top once the list shows those rows.
  var arrivesAtTop = false

  /// Another session opened.
  func reset() {
    visible = []
    topBeforePage = nil
    endSeekingTop()
  }

  /// What a finished read of older history asks for.
  enum PageOutcome {
    /// Nothing more: no jump is under way.
    case settled
    /// Jump to top reads the next page.
    case readNext
    /// Jump to top has read all it can and goes to the top.
    case arrive
  }

  /// A read of older history ended, before or after its rows reach the list. Jump to top keeps
  /// reading while pages add rows and more remain; a failed or empty page ends it where it is.
  /// - Parameters:
  ///   - sourceTop: The first loaded row now.
  ///   - hasMore: Older history remains and can be read.
  /// - Returns: What to do next.
  func pageEnded(sourceTop: String?, hasMore: Bool) -> PageOutcome {
    let added = sourceTop != topBeforePage
    if !added {
      // Nothing lands above, so no row waits to be put back.
      awaitsPage = false
      prependAnchor = nil
    }
    guard seeksTop else { return .settled }
    if added, hasMore { return .readNext }
    arrivesAtTop = true
    return .arrive
  }

  /// Jump to top arrived, or was given up.
  func endSeekingTop() {
    prependAnchor = nil
    awaitsPage = false
    seeksTop = false
    arrivesAtTop = false
  }
}

/// The keys for the previous and next user message (Option-Command-Up and -Down), on buttons
/// that are laid out and never drawn: the transcript shows no control for them.
struct MessageNavigationKeys: ViewModifier {
  /// There is a user message to move between.
  let isEnabled: Bool
  let previous: () -> Void
  let next: () -> Void

  func body(content: Content) -> some View {
    content.overlay(alignment: .bottomTrailing) {
      if isEnabled {
        VStack(spacing: 0) {
          key(AppShortcuts.previousMessage, action: previous)
          key(AppShortcuts.nextMessage, action: next)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
  }

  private func key(_ shortcut: KeyboardShortcut, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Color.clear.frame(width: Theme.Control.target, height: Theme.Control.target)
    }
    .buttonStyle(.plain)
    .keyboardShortcut(shortcut)
  }
}

/// Where the reader is, for the jump-to-top pill: kept out of view state so scrolling does not
/// re-render anything until the pill's visibility changes.
@MainActor
private final class ScrollTopTracker {
  var lastOffset: CGFloat = 0
  var isScrolling = false
  /// The latest scroll up, which the pill stays for ``JumpToTopReveal/scrollReveal`` after.
  var lastRevealAt = ContinuousClock.now
  /// One wait for a whole run of scrolls up: each moves the wait's end, not the task.
  var hideTask: Task<Void, Never>?
}

/// What a scroll does to the "Jump to top" pill. Only the reader's own scrolling (or a jump)
/// should reach it: a layout pass also moves the offset (rows measured, history paged in), and
/// state written from those schedules another pass, which can move it again without end.
enum ScrollTopReveal: Equatable {
  case reveal, hide, unchanged

  /// Whether `offset` (points below the top) is at the top. Once there, a few points of
  /// re-measured rows do not leave it.
  static func isAtTop(_ offset: CGFloat, wasAtTop: Bool) -> Bool {
    offset <= (wasAtTop ? 8 : 1)
  }

  /// The pill's change for a scroll of `delta` points (negative is up).
  static func change(delta: CGFloat, isAtTop: Bool, isRevealed: Bool) -> Self {
    if delta < -1, !isAtTop { return .reveal }
    if delta > 1, isRevealed { return .hide }
    return .unchanged
  }
}

/// The web's hover-revealed "Jump to top" pill: pointing within ``band`` of the transcript's top,
/// or scrolling up, shows a round button centered at the top edge while there is anywhere to go.
struct JumpToTopReveal: ViewModifier {
  /// Older history is still on the server.
  let hasMoreHistory: Bool
  /// Older history is being read.
  let isLoading: Bool
  let jump: () -> Void
  /// The table transcript's scrolls, which no SwiftUI scroll view reports.
  var feed: TranscriptScrollFeed?
  @State private var isHovering = false
  @State private var scrolledUp = false
  @State private var isAtTop = true
  @State private var tracker = ScrollTopTracker()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Points below the top edge that count as pointing at the top.
  static let band: CGFloat = 140
  /// How long the pill stays after the reader stops scrolling up.
  static let scrollReveal: Duration = .seconds(2)

  private var isShown: Bool { (isHovering || scrolledUp) && (hasMoreHistory || !isAtTop) }

  func body(content: Content) -> some View {
    feed?.offsetChanged = { scrolled(to: $0) }
    feed?.scrollPhaseChanged = { isScrolling in
      tracker.isScrolling = isScrolling
      if !isScrolling { updateIsAtTop() }
    }
    return
      content
      .onContinuousHover { phase in
        let hovering =
          switch phase {
          case .active(let location): location.y < Self.band
          case .ended: false
          }
        guard hovering != isHovering else { return }
        if hovering { updateIsAtTop() }
        isHovering = hovering
      }
      // Over the table the feed reports the scrolls: a scroll view here is some row's own.
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentOffset.y + geometry.contentInsets.top
      } action: { _, offset in
        if feed == nil { scrolled(to: offset) }
      }
      .onScrollPhaseChange { _, phase in
        guard feed == nil else { return }
        tracker.isScrolling = phase.isScrolling
        if !phase.isScrolling { updateIsAtTop() }
      }
      .overlay(alignment: .top) { pill }
      .accessibilityAction(named: "Jump to the first message", jump)
  }

  private var pill: some View {
    Button(action: jump) {
      Group {
        if isLoading {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "arrow.up").font(.callout.weight(.semibold))
        }
      }
      .frame(width: 28, height: 28)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .glassSurface(in: Circle(), isInteractive: true)
    .help("Jump to the first message")
    .accessibilityLabel("Jump to the first message")
    .accessibilityIdentifier("transcript-jump-top")
    .padding(.top, Theme.Spacing.small)
    .opacity(isShown ? 1 : 0)
    .allowsHitTesting(isShown)
    .accessibilityHidden(!isShown)
    .animation(
      reduceMotion ? nil : Theme.Motion.animation(.easeOut(duration: 0.15)), value: isShown)
  }

  /// Reveals the pill while the reader scrolls up, and hides it once they stop or turn back.
  private func scrolled(to offset: CGFloat) {
    let delta = offset - tracker.lastOffset
    tracker.lastOffset = offset
    // A layout pass moved the offset, not the reader: no state, so no further pass.
    guard tracker.isScrolling else { return }
    let atTop = updateIsAtTop()
    switch ScrollTopReveal.change(delta: delta, isAtTop: atTop, isRevealed: scrolledUp) {
    case .reveal:
      if !scrolledUp { scrolledUp = true }
      tracker.lastRevealAt = .now
      if tracker.hideTask == nil { tracker.hideTask = Task { await hideOnceStill() } }
    case .hide:
      tracker.hideTask?.cancel()
      tracker.hideTask = nil
      scrolledUp = false
    case .unchanged:
      break
    }
  }

  /// Hides the pill ``scrollReveal`` after the latest scroll up, waiting on while scrolls up
  /// during the wait move its end.
  private func hideOnceStill() async {
    var since = tracker.lastRevealAt
    var end = since + Theme.Timing.pause(Self.scrollReveal)
    while end > .now {
      do {
        try await Task.sleep(until: end, clock: .continuous)
      } catch {
        return  // The reader turned back down, which hid the pill already.
      }
      guard tracker.lastRevealAt != since else { break }
      since = tracker.lastRevealAt
      end = since + Theme.Timing.pause(Self.scrollReveal)
    }
    tracker.hideTask = nil
    scrolledUp = false
  }

  /// Reads the last offset into ``isAtTop``: while scrolling, when a scroll ends, and when the
  /// pointer reaches the top band.
  /// - Returns: Whether the transcript is at its top.
  @discardableResult
  private func updateIsAtTop() -> Bool {
    let atTop = ScrollTopReveal.isAtTop(tracker.lastOffset, wasAtTop: isAtTop)
    if atTop != isAtTop { isAtTop = atTop }
    return atTop
  }
}
