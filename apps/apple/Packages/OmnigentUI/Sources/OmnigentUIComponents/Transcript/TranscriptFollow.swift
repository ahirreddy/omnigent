/// The transcript's reading position rules.
///
/// - It opens following the newest output.
/// - Incoming output scrolls only while following, and never while the user's finger (or
///   trackpad) is moving the transcript; the catch-up waits until the scroll ends.
/// - A user scroll that ends away from the bottom stops following. From then on incoming output
///   never moves the reading position; it marks that there is something new, and "Jump to
///   latest" shows until the user jumps or scrolls back to the bottom.
nonisolated struct TranscriptFollow: Equatable {
  /// Incoming output scrolls to the newest row.
  private(set) var follows = true
  /// The user is dragging or a fling is decelerating.
  private(set) var isUserScrolling = false
  /// Output arrived while the user was reading earlier rows.
  private(set) var hasUnseenOutput = false
  /// The visible bottom is within reach of the content's end.
  private(set) var isNearBottom = true
  /// Output arrived mid-scroll while following; scroll once the user lets go.
  private var owesCatchUp = false

  /// "Jump to latest" shows while not following.
  var showsJumpToLatest: Bool { !follows }

  /// The pill's title.
  var jumpTitle: String { hasUnseenOutput ? "New output" : "Jump to latest" }

  /// The scroll phase changed.
  /// - Parameter isUserScrolling: The user is dragging, interacting or decelerating.
  /// - Returns: Whether to scroll to the newest row now.
  mutating func scrollPhaseChanged(isUserScrolling: Bool) -> Bool {
    let ended = self.isUserScrolling && !isUserScrolling
    self.isUserScrolling = isUserScrolling
    guard ended else { return false }
    let catchUp = owesCatchUp
    owesCatchUp = false
    if isNearBottom { follow() }
    return follows && catchUp
  }

  /// The scroll geometry changed, from a user scroll or from content growing.
  /// - Parameter isNearBottom: The visible bottom is near the content's end.
  mutating func geometryChanged(isNearBottom: Bool) {
    self.isNearBottom = isNearBottom
    // Growth below a still reader is not the reader moving: only a user scroll changes the mode.
    guard isUserScrolling else { return }
    if isNearBottom {
      // Back at the bottom with output the reader has not seen: catch up when they let go.
      if hasUnseenOutput { owesCatchUp = true }
      follow()
    } else {
      follows = false
    }
  }

  /// New output arrived.
  /// - Returns: Whether to scroll to the newest row now.
  mutating func contentChanged() -> Bool {
    guard follows else {
      hasUnseenOutput = true
      return false
    }
    if isUserScrolling {
      owesCatchUp = true
      return false
    }
    return true
  }

  /// The user asked for the newest row (the pill or Jump to Latest).
  /// Rows that resize after layout (a diff preview, an image) keep a following, still reader at
  /// the bottom; they are not new output.
  func layoutGrew() -> Bool {
    follows && !isUserScrolling
  }

  mutating func jumpToLatest() {
    follow()
  }

  /// Another session opened: start again at its newest row.
  mutating func reset() {
    self = Self()
  }

  private mutating func follow() {
    follows = true
    hasUnseenOutput = false
  }
}
