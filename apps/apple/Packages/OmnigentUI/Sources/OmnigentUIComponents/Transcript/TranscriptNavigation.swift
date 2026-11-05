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

  /// Another session opened.
  func reset() {
    visible = []
    prependAnchor = nil
    awaitsPage = false
    seeksTop = false
  }
}

/// Previous and next user message, at the transcript's trailing edge (web `UserMessageNav`).
/// Jump to top is the pill the top edge reveals (``JumpToTopReveal``).
struct TranscriptNavigator: View {
  let previous: () -> Void
  let next: () -> Void
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.composerLayoutStyle) private var composerLayout

  var body: some View {
    // A phone has no room for it: it would cover the last row's trailing actions (a banner's
    // Retry), and the web leaves it out at phone width too.
    if !(layoutWidth == .compact && composerLayout == .touch) { navigator }
  }

  private var navigator: some View {
    VStack(spacing: 0) {
      button(
        "Previous message", shortcut: "\u{2318}\u{2325}\u{2191}", symbol: "chevron.up",
        id: "transcript-previous-message", action: previous
      )
      .keyboardShortcut(AppShortcuts.previousMessage)
      button(
        "Next message", shortcut: "\u{2318}\u{2325}\u{2193}", symbol: "chevron.down",
        id: "transcript-next-message", action: next
      )
      .keyboardShortcut(AppShortcuts.nextMessage)
    }
    .font(Theme.Typography.label)
    .glassSurface(in: Capsule(), isInteractive: true)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Message navigation")
  }

  private func button(
    _ title: String, shortcut: String? = nil, symbol: String, id: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .frame(width: Theme.Control.target, height: Theme.Control.target)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(shortcut.map { "\(title) (\($0))" } ?? title)
    .accessibilityLabel(title)
    .accessibilityIdentifier(id)
  }
}

/// Where the reader is, for the jump-to-top pill: kept out of view state so scrolling does not
/// re-render anything until the pill's visibility changes.
@MainActor
private final class ScrollTopTracker {
  var lastOffset: CGFloat = 0
  var hideTask: Task<Void, Never>?
}

/// The web's hover-revealed "Jump to top" pill: pointing within ``band`` of the transcript's top,
/// or scrolling up, shows a round button centered at the top edge while there is anywhere to go.
struct JumpToTopReveal: ViewModifier {
  /// Older history is still on the server.
  let hasMoreHistory: Bool
  /// Older history is being read.
  let isLoading: Bool
  let jump: () -> Void
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
    content
      .onContinuousHover { phase in
        let hovering =
          switch phase {
          case .active(let location): location.y < Self.band
          case .ended: false
          }
        if hovering != isHovering { isHovering = hovering }
      }
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentOffset.y + geometry.contentInsets.top
      } action: { _, offset in
        scrolled(to: offset)
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
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isShown)
  }

  /// Reveals the pill while the reader scrolls up, and hides it once they stop or turn back.
  private func scrolled(to offset: CGFloat) {
    let atTop = offset <= 1
    if atTop != isAtTop { isAtTop = atTop }
    let delta = offset - tracker.lastOffset
    tracker.lastOffset = offset
    if delta < -1, !atTop {
      if !scrolledUp { scrolledUp = true }
      tracker.hideTask?.cancel()
      tracker.hideTask = Task { @MainActor in
        do {
          try await Task.sleep(for: Self.scrollReveal)
        } catch {
          return  // Superseded by a newer scroll.
        }
        scrolledUp = false
      }
    } else if delta > 1, scrolledUp {
      tracker.hideTask?.cancel()
      scrolledUp = false
    }
  }
}
