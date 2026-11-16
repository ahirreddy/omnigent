#if os(iOS)
  import SwiftUI
  import UIKit

  extension TranscriptCollectionController {
    // MARK: Layout passes

    /// A layout pass is about to place cells: a new viewport size lays the rows out again, and
    /// the rows the pass will show, and those just beyond in the direction the content moved,
    /// are measured first.
    func willLayout() {
      // A hidden tab lays its rows out again only once it shows.
      guard !isAdjusting, isShown else { return }
      let size = collectionView.bounds.size
      if size != laidOutSize {
        laidOutSize = size
        viewportResized()
      }
      measureAhead()
    }

    /// Measures the rows in view and ahead of the scroll that need it. When rows above the
    /// reader's change height, the content moves with the row under the viewport's top; a still
    /// follower stays at the end.
    func measureAhead() {
      guard itemCount > 0, itemCount == model.rows.count, model.width > 0 else { return }
      isAdjusting = true
      defer { isAdjusting = false }
      let height = collectionView.bounds.height
      var top = collectionView.contentOffset.y
      let upward = top < laidOutOffset
      let keepsEnd = follow.layoutGrew() && isNearBottom
      var moved = false
      for _ in 0..<3 {
        let anchor = readingAnchor(atOffset: top)
        let noted = measureRows(at: top, height: height, upward: upward)
        guard !noted.isEmpty else { break }
        noteHeightsInPlace(noted)
        moved = true
        if keepsEnd {
          top = maximumOffset
        } else if let anchor, let index = model.index(of: anchor.id) {
          top = offsets.top(of: index) + anchor.offset - insets.top
        } else {
          break
        }
      }
      if moved, abs(top - collectionView.contentOffset.y) >= 0.5 {
        collectionView.contentOffset.y = top
      }
      laidOutOffset = top
    }

    /// Measures the rows a viewport at content offset `top` shows, then within the budget those
    /// just beyond it in the direction of the scroll.
    /// - Returns: The rows whose heights the layout has to take.
    func measureRows(at top: CGFloat, height: CGFloat, upward: Bool) -> IndexSet {
      let reach = height * Self.lookahead
      let shown = rowsNeedingMeasure(from: top, to: top + height)
      let ahead =
        upward
        ? rowsNeedingMeasure(from: top - reach, to: top, upward: true)
        : rowsNeedingMeasure(from: top + height, to: top + height + reach)
      var noted = IndexSet()
      for index in shown where measureKeeping(index) { noted.insert(index) }
      let deadline = CACurrentMediaTime() + Self.lookaheadBudget
      for index in ahead {
        guard CACurrentMediaTime() < deadline else { break }
        if measureKeeping(index) { noted.insert(index) }
      }
      return noted
    }

    /// The viewport changed size: rows take a new width, and a follower stays at the end. The
    /// reader is where the last layout pass left them, whatever offset the new size came with.
    func viewportResized() {
      let anchor = readingAnchor(atOffset: laidOutOffset)
      guard syncWidth() else {
        if !frameIfReady(), follow.layoutGrew() { pinBottom() }
        return
      }
      widthChanged(keeping: anchor)
    }

    /// Rows on screen are measured at the new width; the others keep their old heights, or
    /// estimates for it, until they come into view. The reader keeps the same share of the row
    /// they read above the viewport's top.
    func widthChanged(keeping anchor: ReadingAnchor?) {
      guard itemCount == model.rows.count else { return }
      measureShownRows()
      rebuildOffsets()
      schedulePrefetch()
      if frameIfReady() { return }
      if follow.layoutGrew() { pinBottom() } else { restore(anchor, proportionally: true) }
    }

    /// Lays rows out at the viewport's width, less the screen's edges beside them.
    /// - Returns: Whether the width changed.
    @discardableResult
    func syncWidth() -> Bool {
      let width = collectionView.bounds.width - insets.left - insets.right
      guard width > 0, model.setWidth(width) else { return false }
      prefetchCursor = nil
      return true
    }

    // MARK: Scroll view delegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      guard !isAdjusting else { return }
      follow.geometryChanged(isNearBottom: isNearBottom)
      checkOlderHistory()
      reportVisibleRows()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      scrollPhaseChanged(isScrolling: true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate { scrollPhaseChanged(isScrolling: false) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
      scrollPhaseChanged(isScrolling: false)
    }

    /// A tap on the status bar scrolls to the top: the reader asked for earlier rows.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
      follow.readEarlier()
      return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
      checkOlderHistory()
    }

    /// The reader started or stopped dragging or flinging: idle measuring waits until they stop.
    func scrollPhaseChanged(isScrolling: Bool) {
      guard isScrolling != isUserScrolling else { return }
      isUserScrolling = isScrolling
      if follow.scrollPhaseChanged(isUserScrolling: isScrolling) { pinBottom() }
      if isScrolling {
        prefetchGeneration += 1
        prefetchCursor = nil
      } else {
        schedulePrefetch()
      }
    }

    // MARK: Geometry

    /// The viewport's height that the bars over it leave the rows.
    var visibleHeight: CGFloat {
      max(0, collectionView.bounds.height - insets.top - insets.bottom)
    }

    var minimumOffset: CGFloat { -insets.top }

    var maximumOffset: CGFloat {
      max(minimumOffset, offsets.contentHeight + insets.bottom - collectionView.bounds.height)
    }

    var isNearBottom: Bool {
      maximumOffset - collectionView.contentOffset.y <= Self.bottomReach
    }

    /// Moves the content offset to `offset`, as the transcript's own move.
    /// - Parameters:
    ///   - offset: The content offset.
    ///   - animated: Scrolls there over a few frames instead of at once.
    func move(to offset: CGFloat, animated: Bool = false) {
      let target = min(max(offset, minimumOffset), maximumOffset)
      let point = CGPoint(x: collectionView.contentOffset.x, y: target)
      if animated {
        collectionView.setContentOffset(point, animated: true)
      } else {
        collectionView.contentOffset = point
        laidOutOffset = target
      }
      follow.geometryChanged(isNearBottom: isNearBottom)
    }

    /// The row under the viewport's top, and how far into it the top is.
    func readingAnchor() -> ReadingAnchor? {
      readingAnchor(atOffset: collectionView.contentOffset.y)
    }

    /// The anchor the viewport would have at content offset `offset`.
    func readingAnchor(atOffset offset: CGFloat) -> ReadingAnchor? {
      let top = offset + insets.top
      guard !offsets.isEmpty, offsets.count == model.rows.count,
        let row = offsets.row(at: max(0, top))
      else { return nil }
      let into = top - offsets.top(of: row)
      let height = offsets.height(of: row)
      return ReadingAnchor(
        id: model.rows[row].id, offset: into, fraction: height > 0 ? into / height : 0)
    }

    /// Puts `anchor`'s row back under the viewport's top.
    /// - Parameters:
    ///   - anchor: The row and the point of it the reader was at.
    ///   - proportionally: Keeps the same share of the row above the top, not the same distance,
    ///     for a row that changed height.
    func restore(_ anchor: ReadingAnchor?, proportionally: Bool = false) {
      guard let anchor, let index = model.index(of: anchor.id), index < offsets.count else {
        return
      }
      let into = proportionally ? anchor.fraction * offsets.height(of: index) : anchor.offset
      let offset = offsets.top(of: index) + into - insets.top
      guard abs(offset - collectionView.contentOffset.y) >= 0.5 else { return }
      move(to: offset)
    }

    /// Measures the rows from the end up through a viewport and a half, then goes to the end.
    /// - Parameter animated: Scrolls there over a few frames, when the end is near.
    func pinBottom(animated: Bool = false) {
      guard !model.rows.isEmpty, offsets.count == model.rows.count else { return }
      var covered: CGFloat = 0
      var noted = IndexSet()
      var index = model.rows.count - 1
      while index >= 0, covered < collectionView.bounds.height * 1.5 {
        if model.needsMeasure(at: index), measureKeeping(index) { noted.insert(index) }
        covered += model.height(at: index)
        index -= 1
      }
      noteHeightsInPlace(noted)
      move(to: maximumOffset, animated: animated)
    }

    /// Opening frames the latest user message at the top, as the stack does, so a long answer
    /// reads from its start; a turn that fits keeps following the end.
    func frameLatestTurn() {
      guard !isCLI, let latest = model.rows.lastIndex(where: \.isUserMessage) else {
        pinBottom()
        return
      }
      var noted = IndexSet()
      for index in latest..<model.rows.count where model.needsMeasure(at: index) {
        if measureKeeping(index) { noted.insert(index) }
        if model.height(at: index) + offsets.top(of: index) - offsets.top(of: latest)
          > visibleHeight * 2
        {
          break
        }
      }
      noteHeightsInPlace(noted)
      let top = offsets.top(of: latest)
      if offsets.contentHeight - top <= visibleHeight {
        pinBottom()
      } else {
        follow.frameLatest()
        move(to: top - insets.top)
        follow.frameLandingWaitEnded()
      }
    }

    /// Follows the newest row again from the end; a short way scrolls there, a long one jumps.
    func jumpToLatest() {
      follow.jumpToLatest()
      let isNear =
        maximumOffset - collectionView.contentOffset.y < visibleHeight * Self.animatedJumpReach
      let reducesMotion = environment.values?.accessibilityReduceMotion ?? false
      pinBottom(animated: isNear && !reducesMotion)
    }

    /// Scrolls row `id` into view; a row the list does not have yet is shown once it does.
    func show(_ id: String, at placement: Placement) {
      // A reader sent to a row is not then framed at the latest turn.
      needsFraming = false
      guard let index = model.index(of: id), offsets.count == model.rows.count else {
        pendingShow = (id, placement)
        return
      }
      pendingShow = nil
      follow.readEarlier()
      var noted = IndexSet()
      var covered: CGFloat = 0
      var row = max(0, index - 1)
      while row < model.rows.count, covered < visibleHeight * 1.5 {
        if model.needsMeasure(at: row), measureKeeping(row) { noted.insert(row) }
        covered += model.height(at: row)
        row += 1
      }
      noteHeightsInPlace(noted)
      let rect = frame(ofRow: index)
      switch placement {
      case .top: move(to: rect.minY - insets.top)
      case .center: move(to: rect.midY - insets.top - visibleHeight / 2)
      }
      reportVisibleRows()
    }

    // MARK: Insets and the keyboard

    /// The bars over the transcript (a toolbar or plan above, the composer and keyboard below)
    /// and the screen's edges beside it. The keyboard's change moves with the keyboard.
    func setInsets(_ edges: EdgeInsets) {
      let isRightToLeft = collectionView.effectiveUserInterfaceLayoutDirection == .rightToLeft
      let next = UIEdgeInsets(
        top: edges.top, left: isRightToLeft ? edges.trailing : edges.leading,
        bottom: edges.bottom, right: isRightToLeft ? edges.leading : edges.trailing)
      guard next != insets else { return }
      let anchor = readingAnchor()
      let grew = next.bottom > insets.bottom
      let sidesChanged = next.left != insets.left || next.right != insets.right
      alongsideKeyboard {
        self.insets = next
        self.collectionView.contentInset = UIEdgeInsets(
          top: next.top, left: 0, bottom: next.bottom, right: 0)
        self.collectionView.verticalScrollIndicatorInsets = UIEdgeInsets(
          top: next.top, left: 0, bottom: next.bottom, right: next.right)
        if sidesChanged, self.syncWidth() {
          self.widthChanged(keeping: anchor)
        } else if grew, self.follow.layoutGrew() {
          self.pinBottom()
        } else {
          self.restore(anchor)
        }
      }
    }

    /// Runs `changes` in the keyboard's animation while it moves, else at once.
    func alongsideKeyboard(_ changes: @escaping () -> Void) {
      let now = CACurrentMediaTime()
      guard let keyboard = keyboardAnimation, now < keyboard.ends else {
        changes()
        return
      }
      let curve = UIView.AnimationOptions(rawValue: keyboard.curve << 16)
      UIView.animate(
        withDuration: keyboard.ends - now, delay: 0,
        options: [curve, .beginFromCurrentState, .allowUserInteraction], animations: changes)
    }

    @objc func keyboardWillChangeFrame(_ note: Notification) {
      let info = note.userInfo
      let duration = info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
      let curve = info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
      guard let duration, duration > 0, let curve else {
        keyboardAnimation = nil
        return
      }
      keyboardAnimation = (curve, CACurrentMediaTime() + duration)
    }

    /// The tab hid or shows: a hidden transcript measures nothing while idle.
    func setShown(_ isShown: Bool) {
      guard isShown != self.isShown else { return }
      self.isShown = isShown
      guard isShown else { return }
      collectionView.setNeedsLayout()
      schedulePrefetch()
    }
  }
#endif
