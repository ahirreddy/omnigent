/// The transcript's reading position rules.
///
/// - It opens following the newest output, then frames the latest question: a turn too long to
///   fit stops following there, where the reader starts its answer.
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
  /// Opening scrolled to the latest question and hasn't heard where that landed.
  private var awaitsFrameLanding = false

  /// How long a framing scroll may take to report leaving the end. It lands in the next layout,
  /// which a busy main thread can hold back well past the next turn of its queue.
  static let frameLandingWait = Duration.milliseconds(500)

  /// "Jump to latest" shows while not following, except while framing is still at the end.
  var showsJumpToLatest: Bool { !follows && !(awaitsFrameLanding && isNearBottom) }

  /// The pill's title.
  var jumpTitle: String { pill.title }

  /// What the "Jump to latest" pill shows. The transcript re-renders only when this changes,
  /// not for every change of the rules' other state.
  struct Pill: Equatable {
    var isShown = false
    var hasUnseenOutput = false

    var title: String { hasUnseenOutput ? "New output" : "Jump to latest" }
  }

  /// The pill's look now.
  var pill: Pill { Pill(isShown: showsJumpToLatest, hasUnseenOutput: hasUnseenOutput) }

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

  /// The user navigated to an earlier message: stop following, as a scroll up would.
  mutating func readEarlier() {
    follows = false
    owesCatchUp = false
    awaitsFrameLanding = false
  }

  /// Opening a session scrolls to its latest question: nothing follows until that lands.
  mutating func frameLatest() {
    readEarlier()
    awaitsFrameLanding = true
  }

  /// No word that framing left the end, so the turn fits and the reader keeps following.
  mutating func frameLandingWaitEnded() {
    guard awaitsFrameLanding else { return }
    awaitsFrameLanding = false
    if isNearBottom { follow() }
  }

  /// Another session opened: start again at its newest row.
  mutating func reset() {
    self = Self()
  }

  private mutating func follow() {
    follows = true
    hasUnseenOutput = false
    awaitsFrameLanding = false
  }
}
