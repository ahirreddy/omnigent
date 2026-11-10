import SwiftUI

/// The transcript's reading rules and reading anchor, kept outside view state: scroll and
/// geometry callbacks (several a frame while the keyboard, a rotation or a resize moves the
/// transcript) update them without re-rendering it. Not observed.
@MainActor
final class TranscriptScrollState {
  /// The limits a new transcript's layout scrolls get; a test lifts them to watch layout
  /// unchecked.
  static var layoutScrollLimits = LayoutScrollBudget.Limits()

  var follow = TranscriptFollow() {
    didSet { if follow.pill != oldValue.pill { showPill(follow.pill) } }
  }
  /// Shows the follow rules' pill; the transcript sets it.
  var showPill: (TranscriptFollow.Pill) -> Void = { _ in }
  /// Scrolls a row to an anchor; the transcript sets it to its scroll view's proxy.
  var scrollToRow: (String, UnitPoint) -> Void = { _, _ in }
  /// Scrolls to the content's end by its edge, and lets go of it (``EndByEdge``).
  var scrollToEnd: () -> Void = {}
  var releaseEnd: () -> Void = {}
  /// The transcript's row ids, top to bottom; the transcript sets it.
  var rowOrder: () -> [String] = { [] }
  private var followedHeights = FollowedHeights()
  private var budget = LayoutScrollBudget(TranscriptScrollState.layoutScrollLimits)
  /// A block on the main run loop will end the budget's turn.
  private var awaitsTurnEnd = false
  /// A turn is ending: what it scrolls is laid out by the display's next pass.
  private var isEndingTurn = false
  /// A timer will look whether layout has come to rest.
  private var awaitsRestCheck = false
  /// How long a width change keeps putting its reader back.
  static let restoreWindow: TimeInterval = 1
  /// How close to the wanted point of a row, as a fraction of the row, counts as there.
  static let restoreReach = 0.01
  /// The loop report's name for a passage the turn's end had to end, short of its layout pass.
  static let latePassage = "transcript passage late"

  /// The width the rows are laid out at, which follows the viewport's.
  let rowWidth = TranscriptRowWidth()
  /// The scroll view is at its top.
  private var isAtTop = false
  /// The scroll view against its content's end, and a return to it by edge.
  var end = TranscriptEnd()
  /// The row under the viewport's middle.
  private var anchor: TranscriptReadingAnchor?
  /// The reader a width change is putting back where they were.
  private var restore: Restore?
  /// A passage ended since the main thread was last at its run loop.
  private var passedThisTurn = false
  /// A passage is under way or just ended: its own scrolls put the reader back.
  private var isPassing: Bool { rowWidth.passage != nil || passedThisTurn }

  private struct Restore {
    /// The row to put back at the viewport's middle; `nil` for a reader at the end.
    var anchor: TranscriptReadingAnchor?
    var since: Date
    /// Scrolls left: one by estimate can land on another row, and the row's new height moves
    /// the point the reader was at.
    var scrollsLeft = 8
    /// The row the last scroll to the wanted one put under the viewport's middle.
    var landed: String?
  }
  /// A short number for this transcript in loop reports.
  private(set) lazy var probeTag = Int(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 10_000)

  /// Records the row under the viewport's middle, and scrolls again while a width change's
  /// reader is not back where they were.
  func record(_ sample: TranscriptReadingAnchor, at now: Date = Date()) {
    probe("transcript reading anchor", "\(sample)")
    // Rows passed at the top on a width change's way are not what the reader reads.
    guard rowWidth.passage == nil else {
      retryTop()
      return
    }
    guard activeRestore(at: now) == nil || !isAtTop else { return }
    anchor = sample
    continueRestore(at: now)
  }

  /// The scroll view reached or left its end or its bottom row, as it does when a scroll there
  /// lands short of where the rows then turn out to end.
  func endChanged(at now: Date = Date()) {
    continueRestore(at: now)
  }

  /// The restore still under way at `now`: for ``restoreWindow``, and while it has scrolls.
  private func activeRestore(at now: Date) -> Restore? {
    guard let restore else { return nil }
    let isOver = now.timeIntervalSince(restore.since) >= Self.restoreWindow
    if restore.scrollsLeft == 0 || isOver { self.restore = nil }
    return self.restore
  }

  /// Scrolls a width change's reader back again unless they are there: to the end, or to
  /// their row, by its own layout once it is in view, which is exact, and by its old one before.
  private func continueRestore(at now: Date) {
    // The edge holds the scroll view at the end while the rows there are measured.
    guard !end.returnsByEdge else {
      if end.isAtEnd { restOnBottomRow() }
      return
    }
    guard var restore = activeRestore(at: now), !isRestored(restore) else { return }
    restore.scrollsLeft -= 1
    self.restore = restore
    // A scroll that lands elsewhere and reports nothing is seen when the turn ends.
    awaitTurnEnd()
    probe("transcript restore", "\(restore.anchor?.id ?? "end"), \(restore.scrollsLeft) left")
    guard let wanted = restore.anchor else {
      end.awaitsLanding = true
      scrollToRow(TranscriptView.bottomID, .bottom)
      return
    }
    // A scroll by estimate that lands on the same other row twice is not getting nearer.
    guard let landed = anchor?.id, landed != wanted.id, landed == restore.landed,
      let target = TranscriptReadingAnchor.counterTarget(
        wanted: wanted.id, landed: landed, in: rowOrder())
    else {
      self.restore?.landed = anchor?.id
      let layout = anchor.flatMap { $0.id == wanted.id ? $0 : nil } ?? wanted
      scrollToRow(wanted.id, wanted.unitPoint(in: layout))
      return
    }
    probe("transcript restore", "by way of \(target)")
    self.restore?.landed = nil
    scrollToRow(target, wanted.unitPoint(in: wanted))
  }

  /// Whether the reader of `restore` is where it wants them.
  private func isRestored(_ restore: Restore) -> Bool {
    guard let wanted = restore.anchor else { return !end.wantsBottomRow }
    guard let anchor, anchor.id == wanted.id else { return false }
    return abs(anchor.fraction - wanted.fraction) <= Self.restoreReach
  }

  /// The viewport offers the rows `width`, which they have not been laid out at yet.
  func rowWidthOffered(_ width: CGFloat, at now: Date = Date()) {
    guard rowWidth.offer(width) else { return }
    budget.viewportChanged(.width, to: width)
    probe("transcript width", "\(width), \(follow)")
    takeWidth(at: now)
  }

  /// Gives the rows the viewport's width: through a passage for a reader with rows above,
  /// one a turn, and in place otherwise.
  private func takeWidth(at now: Date) {
    // A passage under way takes the latest width at the top.
    guard rowWidth.passage == nil else { return }
    // A reader still being put back is going where that restore takes them.
    let pending = activeRestore(at: now)
    let toEnd = pending.map { $0.anchor == nil } ?? (end.isNearBottom || follow.layoutGrew())
    let place = pending?.anchor ?? anchor
    // At the top no row lies above.
    guard !isAtTop, toEnd || place != nil else {
      rowWidth.catchUp()
      return
    }
    // Rows put back once this turn have not settled: the next passage waits for its end.
    guard !passedThisTurn else { return }
    // A refused scroll leaves the scroll view to itself.
    guard allowsScroll("width", keepsBottom: toEnd) else {
      rowWidth.catchUp()
      return
    }
    restore = nil
    rowWidth.passage = TranscriptRowWidth.Passage(anchor: toEnd ? nil : place)
    scrollToRow(TranscriptView.topID, .top)
  }

  /// A row moved under the viewport's middle with a passage short of the top: the scroll view
  /// kept its own anchor through a size change in the same pass, and is sent there again.
  private func retryTop() {
    guard !isAtTop, rowWidth.passage?.takesTopScroll() == true else { return }
    probe("transcript passage", "to the top again")
    scrollToRow(TranscriptView.topID, .top)
  }

  /// The scroll view reached or left its top; there the rows of a passage take their width.
  func topReached(_ isAtTop: Bool) {
    self.isAtTop = isAtTop
    guard isAtTop, rowWidth.passage?.hasWidth == false else { return }
    // The viewport came back to the rows' width on the way: nothing to lay out.
    guard rowWidth.isBehind else {
      endPassage()
      return
    }
    probe("transcript passage", "at the top")
    rowWidth.passage?.hasWidth = true
    rowWidth.catchUp()
  }

  /// The rows were laid out at a new width: a passage ends, unless the viewport offered
  /// another width meanwhile, which they take at the top as well.
  func rowsResized() {
    guard rowWidth.passage?.hasWidth == true else { return }
    if rowWidth.isBehind { rowWidth.catchUp() } else { endPassage() }
  }

  /// Puts a passage's reader back with the rows at the viewport's width: at the end, or at
  /// their row, by its old height first; one who jumped on the way goes where they jumped.
  private func endPassage(at now: Date = Date()) {
    guard let passage = rowWidth.passage else { return }
    rowWidth.passage = nil
    rowWidth.catchUp()
    probe("transcript passage", "ends at \(passage.jump ?? passage.anchor?.id ?? "end")")
    passedThisTurn = true
    awaitTurnEnd()
    // A jump that landed on the way is where the reader goes.
    if let jump = passage.jump {
      scrollToRow(jump, .top)
      return
    }
    restore = Restore(anchor: passage.anchor, since: now)
    // By edge the scroll view builds the rows at its end alone. A scroll to the bottom row
    // from the top builds every row on the way when the rows' estimated heights disagree.
    guard let anchor = passage.anchor else {
      end.returnsByEdge = true
      scrollToEnd()
      return
    }
    scrollToRow(anchor.id, anchor.unitPoint(in: anchor))
  }

  /// Whether a following transcript scrolls for content growing from `start` to `height`.
  func follows(_ height: CGFloat, from start: CGFloat) -> Bool {
    followedHeights.follows(height, from: start)
  }

  /// New output arrived or rows changed, which pays for the scrolls its layout asks for.
  func contentChanged() {
    probe("transcript rows changed", "\(budget)")
    budget.contentChanged()
  }

  /// The reader scrolled or jumped. A passage under way goes on: its own scrolls end a
  /// gesture's phase too, and rows taking their width where the reader is would all be built.
  func readerMoved() {
    budget.readerMoved()
    restore = nil
    leaveEdge()
  }

  /// The reader jumped to a row, where a passage under way then ends. An animated jump lays
  /// out the rows on the way at every frame, so a stall that follows one should name it.
  func jumped(to target: String) {
    probe("transcript jump", target)
    readerMoved()
    rowWidth.passage?.jump(to: target, end: TranscriptView.bottomID)
  }

  /// Another session's rows replaced the ones a passage set out from, and take the width as
  /// they open.
  func sessionOpened() {
    readerMoved()
    rowWidth.passage = nil
    rowWidth.catchUp()
  }

  /// The first row changed, as it does when older rows land above the ones in view.
  func firstRowChanged() {
    probe("transcript first row", "\(budget)")
  }

  /// The content's height changed.
  /// - Returns: Whether a following transcript scrolls to the bottom for it.
  func contentHeightChanged(_ height: CGFloat, from start: CGFloat) -> Bool {
    budget.layoutChanged()
    return height > start && !isPassing && follow.layoutGrew()
      && follows(height, from: start) && allowsScroll("content height", keepsBottom: true)
  }

  /// The dock's inset changed.
  /// - Returns: Whether a following transcript scrolls to the bottom, its newest rows covered.
  func dockChanged(_ inset: CGFloat, from old: CGFloat) -> Bool {
    budget.viewportChanged(.dock, to: inset)
    return inset > old && !isPassing && follow.layoutGrew()
      && allowsScroll("dock inset", keepsBottom: true)
  }

  /// Whether a scroll that layout asked for may run (``LayoutScrollBudget``).
  /// - Parameters:
  ///   - reason: What asked, for loop reports.
  ///   - keepsBottom: The scroll keeps a reader at the bottom.
  /// - Returns: Whether to scroll.
  func allowsScroll(_ reason: String, keepsBottom: Bool) -> Bool {
    awaitTurnEnd()
    let allowed = budget.spend(keepsBottom: keepsBottom)
    if allowed {
      probe("transcript layout scroll", "\(reason), \(budget)")
    } else {
      probe("transcript scroll refused", "\(reason), \(budget)")
      checkForRest()
    }
    return allowed
  }

  /// Has the main thread's return to its run loop end this turn.
  func awaitTurnEnd() {
    guard !awaitsTurnEnd else { return }
    awaitsTurnEnd = true
    let ended: @Sendable () -> Void = { [weak self] in
      MainActor.assumeIsolated { self?.turnEnded() }
    }
    // The turn after one that scrolled as it ended ends once the display has laid that out.
    if isEndingTurn { MainRunLoop.performAfterDisplay(ended) } else { MainRunLoop.perform(ended) }
  }

  /// A scroll to the bottom refused with the budget spent runs once layout has been still
  /// for the budget's quiet time, so a long run of late-sizing rows still ends at the bottom.
  private func checkForRest() {
    guard budget.awaitsRest, !awaitsRestCheck else { return }
    awaitsRestCheck = true
    MainRunLoop.perform(after: budget.untilRest() + budget.limits.quiet * 0.1) { [weak self] in
      MainActor.assumeIsolated { self?.restChecked() }
    }
  }

  private func restChecked() {
    awaitsRestCheck = false
    guard budget.rested() else {
      checkForRest()
      return
    }
    if follow.layoutGrew(), allowsScroll("rest", keepsBottom: true) {
      scrollToRow(TranscriptView.bottomID, .bottom)
    }
  }

  /// The main thread is back at its run loop: a width change's reader is put where they
  /// should be, and a scroll to the bottom refused only for the turn that ended runs now,
  /// unless the reader took over.
  private func turnEnded(at now: Date = Date()) {
    awaitsTurnEnd = false
    isEndingTurn = true
    defer { isEndingTurn = false }
    settleFollow()
    end.awaitsLanding = false
    // A passage ends in the layout pass it began in; one still open is not left at the top.
    // Otherwise the rows' heights have settled, and a scroll to the reader's place lands on it.
    if rowWidth.passage != nil {
      probe(Self.latePassage, "\(follow)")
      endPassage(at: now)
    } else if !restOnBottomRow() {
      continueRestore(at: now)
    }
    passedThisTurn = false
    if budget.turnEnded(), !follow.isUserScrolling, allowsScroll("turn end", keepsBottom: true) {
      scrollToRow(TranscriptView.bottomID, .bottom)
    }
    // A width offered after the turn's passage is taken now.
    if rowWidth.isBehind { takeWidth(at: now) }
  }

  /// Records a scroll geometry change for ``LoopProbe``, counted for this transcript alone so
  /// several windows changing at once do not add up to a loop. `detail` must hold nothing a
  /// conversation says: a loop's line reaches the unified log.
  func probe(_ name: String, _ detail: @autoclosure () -> String) {
    LoopProbe.record(name, tag: probeTag, detail())
  }
}

extension EnvironmentValues {
  /// The transcript's scroll state, for rows reporting the reading anchor.
  @Entry var transcriptScrollState: TranscriptScrollState?
}

extension View {
  /// Records this row's height for ``LoopProbe`` in Debug builds, so a loop names the row.
  @ViewBuilder func probesRowHeight(_ id: String) -> some View {
    #if DEBUG
      modifier(RowHeightProbe(id: id))
    #else
      self
    #endif
  }
}

#if DEBUG
  private struct RowHeightProbe: ViewModifier {
    let id: String
    @Environment(\.transcriptScrollState) private var scroll

    func body(content: Content) -> some View {
      content.onGeometryChange(for: CGSize.self) { [id] proxy in
        HangTrace.pass("row \(id)")
        return proxy.size
      } action: { old, new in
        scroll?.probe(
          "transcript row height",
          "\(id) \(old.width)x\(old.height) -> \(new.width)x\(new.height)")
      }
    }
  }
#endif
