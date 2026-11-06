import SwiftUI

/// A collapsed sidebar peeking over the content, as in Arc: resting the pointer on the window's
/// leading edge reveals it, and moving out of it hides it again. Pinning the sidebar ends the
/// peek (``reset()``).
///
/// The pointer is read as its distance from the leading edge. Each delay is a ``Timer`` the
/// caller runs while it is pending and reports back, so a later move supersedes it.
nonisolated struct SidebarPeek: Equatable {
  /// Where the peek is.
  enum Phase: Equatable {
    /// Not showing.
    case hidden
    /// The pointer rests on the edge; the panel shows when the timer with this token fires.
    case revealing(Int)
    /// Showing over the content.
    case shown
    /// The pointer left the panel; it hides when the timer with this token fires.
    case hiding(Int)
  }

  /// A delay the caller runs, then reports with ``timerFired(_:)``.
  struct Timer: Equatable {
    let token: Int
    let delay: Duration
  }

  /// How far from the leading edge the pointer reveals the panel.
  static let edgeWidth: CGFloat = 6
  /// How long the pointer rests on the edge first, so passing over it does not flash the panel.
  static let revealDelay = Duration.milliseconds(120)
  /// How long the panel stays after the pointer leaves it.
  static let hideDelay = Duration.milliseconds(350)

  private(set) var phase: Phase
  private var lastToken = 0

  /// Creates a peek.
  /// - Parameter isShown: Start showing, as a screenshot does.
  init(isShown: Bool = false) {
    phase = isShown ? .shown : .hidden
  }

  /// Whether the panel shows.
  var isShown: Bool {
    switch phase {
    case .shown, .hiding: true
    case .hidden, .revealing: false
    }
  }

  /// The delay to run now, if one is pending.
  var pendingTimer: Timer? {
    switch phase {
    case .revealing(let token): Timer(token: token, delay: Self.revealDelay)
    case .hiding(let token): Timer(token: token, delay: Self.hideDelay)
    case .hidden, .shown: nil
    }
  }

  /// The pointer moved within the window, or left it.
  /// - Parameters:
  ///   - offset: The pointer's distance from the window's leading edge; `nil` outside it.
  ///   - panelWidth: The panel's width: inside it, the panel stays.
  ///   - isBlocked: A drag, sheet or alert is in progress: the edge reveals nothing, and a
  ///     shown panel stays (its own dialogs present from it).
  mutating func pointerMoved(to offset: CGFloat?, panelWidth: CGFloat, isBlocked: Bool) {
    let onEdge = offset.map { $0 <= Self.edgeWidth } ?? false
    let onPanel = offset.map { $0 <= panelWidth } ?? false
    switch phase {
    case .hidden:
      if onEdge, !isBlocked { phase = .revealing(nextToken()) }
    case .revealing:
      if !onEdge || isBlocked { phase = .hidden }
    case .shown:
      if !onPanel, !isBlocked { phase = .hiding(nextToken()) }
    case .hiding:
      if onPanel || isBlocked { phase = .shown }
    }
  }

  /// A timer from ``pendingTimer`` finished.
  /// - Parameter token: Its token; a superseded timer changes nothing.
  mutating func timerFired(_ token: Int) {
    switch phase {
    case .revealing(token): phase = .shown
    case .hiding(token): phase = .hidden
    default: break
    }
  }

  /// Ends the peek at once, as when the sidebar is pinned.
  mutating func reset() {
    phase = .hidden
  }

  private mutating func nextToken() -> Int {
    lastToken += 1
    return lastToken
  }
}
