import Foundation

/// How many scrolls layout alone may ask of a transcript. A scroll to the bottom has the lazy
/// rows above estimated again, which can change the very geometry that asked for it; unchecked,
/// that repeats without the main thread returning to its run loop. Something happening pays for
/// a few scrolls: new content, the reader moving, a viewport size it has not just had, layout
/// having been still a while. Layout answering its own scrolls uses them up and is refused
/// until something happens again; a reader at the bottom is put back there once layout rests.
nonisolated struct LayoutScrollBudget: Equatable, CustomStringConvertible {
  /// How many scrolls are paid for.
  struct Limits: Equatable {
    /// Scrolls one cause pays for.
    var perCause = 24
    /// Scrolls before the main thread is next back at its run loop.
    var perTurn = 4
    /// How long layout must be still before its next change pays for scrolls: a loop changes
    /// every frame, a reader opening a card now and then does not.
    var quiet: TimeInterval = 1

    /// No limit, to watch what layout does unchecked.
    static let none = Self(perCause: .max, perTurn: .max)
  }

  /// A part of the viewport that layout or the user resizes.
  enum Side: Equatable {
    case width
    case dock
  }

  /// How many times a size may be reached within ``memory`` and still pay for scrolls: a resize
  /// passes a size a few times, a loop keeps returning to the same ones.
  static let repeats = 3
  /// How long a size counts as recent after it last came back.
  static let memory: TimeInterval = 2

  private struct Seen: Equatable {
    var side: Side
    var size: CGFloat
    var seenAt: Date
    var count = 1
  }

  let limits: Limits
  private var remaining: Int
  private var spentThisTurn = 0
  private var owesBottom = false
  /// A scroll to the bottom was refused with the budget spent, and waits for layout to rest.
  private(set) var awaitsRest = false
  private var seen: [Seen] = []
  private var lastChange: Date?

  init(_ limits: Limits = Limits()) {
    self.limits = limits
    remaining = limits.perCause
  }

  var description: String {
    "\(remaining) left, \(spentThisTurn) this turn\(owesBottom ? ", owes the bottom" : "")"
      + (awaitsRest ? ", awaits rest" : "")
  }

  /// New output arrived or rows changed.
  mutating func contentChanged() {
    remaining = limits.perCause
  }

  /// The reader scrolled, jumped or opened another session: what layout owed them is void.
  mutating func readerMoved() {
    remaining = limits.perCause
    owesBottom = false
    awaitsRest = false
  }

  /// A side of the viewport changed size, which pays for scrolls unless the size keeps
  /// coming back.
  mutating func viewportChanged(_ side: Side, to size: CGFloat, at now: Date = Date()) {
    layoutChanged(at: now)
    seen.removeAll { now.timeIntervalSince($0.seenAt) > Self.memory }
    if let index = seen.firstIndex(where: { $0.side == side && abs($0.size - size) < 1 }) {
      seen[index].seenAt = now
      seen[index].count += 1
      if seen[index].count > Self.repeats { return }
    } else {
      seen.append(Seen(side: side, size: size, seenAt: now))
    }
    remaining = limits.perCause
  }

  /// The content's height changed, or layout asked for a scroll. The first change after the
  /// quiet time without one pays for scrolls.
  mutating func layoutChanged(at now: Date = Date()) {
    if let lastChange, now.timeIntervalSince(lastChange) > limits.quiet {
      remaining = limits.perCause
    }
    lastChange = now
  }

  /// Takes one scroll from the budget.
  /// - Parameters:
  ///   - keepsBottom: The scroll keeps a reader at the bottom, so one refused only for this
  ///     turn is owed when the turn ends, and one refused with the budget spent when layout rests.
  ///   - now: The time of the scroll.
  /// - Returns: Whether to scroll.
  mutating func spend(keepsBottom: Bool, at now: Date = Date()) -> Bool {
    layoutChanged(at: now)
    guard remaining > 0 else {
      if keepsBottom { awaitsRest = true }
      return false
    }
    guard spentThisTurn < limits.perTurn else {
      if keepsBottom { owesBottom = true }
      return false
    }
    remaining -= 1
    spentThisTurn += 1
    if keepsBottom { awaitsRest = false }
    return true
  }

  /// Whether the scroll to the bottom that waits for layout to rest is due: nothing changed
  /// for the quiet time, which a loop never allows.
  mutating func rested(at now: Date = Date()) -> Bool {
    guard awaitsRest, let lastChange, now.timeIntervalSince(lastChange) > limits.quiet
    else { return false }
    awaitsRest = false
    return true
  }

  /// How long until layout will have rested, if nothing changes meanwhile.
  func untilRest(at now: Date = Date()) -> TimeInterval {
    guard let lastChange else { return 0 }
    return max(0, limits.quiet - now.timeIntervalSince(lastChange))
  }

  /// The main thread got back to its run loop.
  /// - Returns: Whether a scroll to the bottom is owed from the turn that ended.
  mutating func turnEnded() -> Bool {
    spentThisTurn = 0
    let owed = owesBottom
    owesBottom = false
    return owed
  }
}
