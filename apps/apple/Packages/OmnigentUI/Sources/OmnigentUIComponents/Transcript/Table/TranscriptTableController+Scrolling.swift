#if os(macOS)
  import AppKit
  import SwiftUI

  extension TranscriptTableController {
    // MARK: Scrolling

    /// The clip view is about to move to `proposed`: the rows it will show, and those just
    /// beyond in the direction it moves, are measured first, and the origin moves with the
    /// row under the viewport's top when rows above it change height.
    func clipWillMove(to proposed: NSPoint) -> NSPoint {
      guard !isAdjusting, !model.rows.isEmpty, model.width > 0 else { return proposed }
      isAdjusting = true
      defer { isAdjusting = false }
      let height = clipView.bounds.height
      let upward = proposed.y < clipView.bounds.minY
      var origin = proposed
      for _ in 0..<3 {
        let visible = NSRect(x: 0, y: origin.y, width: model.width, height: height)
        let reach = height * Self.lookahead
        let ahead =
          upward
          ? NSRect(x: 0, y: origin.y - reach, width: model.width, height: reach)
          : NSRect(x: 0, y: origin.y + height, width: model.width, height: reach)
        let shown = rowsNeedingMeasure(in: visible)
        let next = rowsNeedingMeasure(in: ahead, upward: upward)
        guard !shown.isEmpty || !next.isEmpty else { break }
        let anchorRow = tableView.row(at: NSPoint(x: 1, y: max(0, origin.y + insets.top)))
        let anchorOffset = anchorRow >= 0 ? origin.y - tableView.rect(ofRow: anchorRow).minY : 0
        var noted = IndexSet()
        for index in shown where measureKeeping(index) { noted.insert(index) }
        let deadline = CACurrentMediaTime() + Self.lookaheadBudget
        for index in next {
          guard CACurrentMediaTime() < deadline else { break }
          if measureKeeping(index) { noted.insert(index) }
        }
        guard !noted.isEmpty else { break }
        noteHeightsInPlace(noted)
        guard anchorRow >= 0 else { break }
        origin.y = tableView.rect(ofRow: anchorRow).minY + anchorOffset
      }
      return origin
    }

    @objc func clipBoundsChanged(_ note: Notification) {
      clipDidMove()
    }

    /// The clip view moved, for the reader or for the transcript's own reasons.
    func clipDidMove() {
      guard !isAdjusting else { return }
      follow.geometryChanged(isNearBottom: isNearBottom)
      checkOlderHistory()
      reportVisibleRows()
    }

    func withoutAnimation(_ body: () -> Void) {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        context.allowsImplicitAnimation = false
        body()
      }
    }

    @objc func liveScrollStarted(_ note: Notification) {
      isLiveScrolling = true
      scrollPhaseChanged()
    }

    @objc func liveScrollEnded(_ note: Notification) {
      isLiveScrolling = false
      scrollPhaseChanged()
    }

    /// A wheel or trackpad event reached the scroll view. Outside a gesture's live scroll (a
    /// mouse wheel, or a trackpad before its phase begins) it counts as the reader scrolling
    /// until no event follows within ``wheelEnd``.
    func readerScrolled() {
      guard !isLiveScrolling else { return }
      wheelSteps += 1
      let step = wheelSteps
      if !isWheeling {
        isWheeling = true
        scrollPhaseChanged()
      }
      MainRunLoop.perform(after: Self.wheelEnd) { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.wheelSteps == step, self.isWheeling else { return }
          self.isWheeling = false
          self.scrollPhaseChanged()
        }
      }
    }

    /// The reader started or stopped scrolling: idle measuring waits until they stop.
    func scrollPhaseChanged() {
      let isScrolling = isLiveScrolling || isWheeling
      if follow.scrollPhaseChanged(isUserScrolling: isScrolling) { pinBottom() }
      if isScrolling {
        prefetchGeneration += 1
        prefetchCursor = nil
      } else {
        schedulePrefetch()
      }
    }

    /// The viewport's height that the bars over it leave the rows.
    var visibleHeight: CGFloat {
      max(0, clipView.bounds.height - insets.top - insets.bottom)
    }

    /// The rows' height, without the table's filler below a short transcript.
    var contentHeight: CGFloat {
      guard let last = model.rows.indices.last, last < tableView.numberOfRows else { return 0 }
      return tableView.rect(ofRow: last).maxY
    }

    var minimumOffset: CGFloat { -insets.top }

    var maximumOffset: CGFloat {
      max(minimumOffset, contentHeight + insets.bottom - clipView.bounds.height)
    }

    var isNearBottom: Bool {
      maximumOffset - clipView.bounds.minY <= Self.bottomReach
    }

    /// Moves the viewport's origin to `offset`, as the transcript's own move.
    func move(to offset: CGFloat) {
      let target = min(max(offset, minimumOffset), maximumOffset)
      clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: target))
      scrollView.reflectScrolledClipView(clipView)
      follow.geometryChanged(isNearBottom: isNearBottom)
    }

    /// The row under the viewport's top, and how far into it the top is.
    func readingAnchor() -> ReadingAnchor? {
      guard !model.rows.isEmpty, tableView.numberOfRows == model.rows.count else { return nil }
      let top = clipView.bounds.minY + insets.top
      let row = tableView.row(at: NSPoint(x: 1, y: max(0, top)))
      guard model.rows.indices.contains(row) else { return nil }
      return ReadingAnchor(id: model.rows[row].id, offset: top - tableView.rect(ofRow: row).minY)
    }

    /// Puts `anchor`'s row back under the viewport's top.
    func restore(_ anchor: ReadingAnchor?) {
      guard let anchor, let index = model.index(of: anchor.id) else { return }
      let offset = tableView.rect(ofRow: index).minY + anchor.offset - insets.top
      guard abs(offset - clipView.bounds.minY) >= 0.5 else { return }
      move(to: offset)
    }

    /// Measures the rows from the end up through a viewport and a half, then goes to the end.
    func pinBottom() {
      guard !model.rows.isEmpty else { return }
      var covered: CGFloat = 0
      var noted = IndexSet()
      var index = model.rows.count - 1
      while index >= 0, covered < clipView.bounds.height * 1.5 {
        if model.needsMeasure(at: index), measureKeeping(index) { noted.insert(index) }
        covered += model.height(at: index)
        index -= 1
      }
      noteHeightsInPlace(noted)
      move(to: maximumOffset)
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
        if tableView.rect(ofRow: index).minY - tableView.rect(ofRow: latest).minY
          > visibleHeight * 2
        {
          break
        }
      }
      noteHeightsInPlace(noted)
      let top = tableView.rect(ofRow: latest).minY
      if contentHeight - top <= visibleHeight {
        pinBottom()
      } else {
        follow.frameLatest()
        move(to: top - insets.top)
        follow.frameLandingWaitEnded()
      }
    }

    /// Follows the newest row again from the end.
    func jumpToLatest() {
      follow.jumpToLatest()
      pinBottom()
    }

    /// Scrolls row `id` into view; a row the table does not have yet is shown once it does.
    func show(_ id: String, at placement: Placement) {
      // A reader sent to a row is not then framed at the latest turn.
      needsFraming = false
      guard let index = model.index(of: id) else {
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
      let rect = tableView.rect(ofRow: index)
      switch placement {
      case .top: move(to: rect.minY - insets.top)
      case .center: move(to: rect.midY - insets.top - visibleHeight / 2)
      }
      reportVisibleRows()
    }

    /// The bars over the transcript: a toolbar or plan above, the composer below.
    func setInsets(_ edges: EdgeInsets) {
      let next = NSEdgeInsets(top: edges.top, left: 0, bottom: edges.bottom, right: 0)
      guard next.top != insets.top || next.bottom != insets.bottom else { return }
      let grew = next.bottom > insets.bottom
      let anchor = readingAnchor()
      insets = next
      scrollView.contentInsets = next
      if grew, follow.layoutGrew() { pinBottom() } else { restore(anchor) }
    }

    /// The viewport changed size: rows take a new width, and a follower stays at the end.
    func viewportResized() {
      let anchor = readingAnchor()
      guard syncWidth() else {
        if !frameIfReady(), follow.layoutGrew() { pinBottom() }
        return
      }
      // Rows on screen are measured at the new width; the others keep their old heights, or
      // estimates for it, until they come into view.
      tableView.enumerateAvailableRowViews { _, row in
        if let cell = realizedCell(at: row) { measure(row, with: cell) }
      }
      noteHeightsInPlace(IndexSet(integersIn: 0..<model.rows.count))
      schedulePrefetch()
      if frameIfReady() { return }
      if follow.layoutGrew() { pinBottom() } else { restore(anchor) }
    }

    /// Lays rows out at the viewport's width.
    /// - Returns: Whether the width changed.
    @discardableResult
    func syncWidth() -> Bool {
      let width = clipView.bounds.width
      guard width > 0, model.setWidth(width) else { return false }
      column.width = width
      prefetchCursor = nil
      return true
    }

    /// The tab hid or shows: a hidden transcript measures nothing while idle.
    func setShown(_ isShown: Bool) {
      self.isShown = isShown
      if isShown { schedulePrefetch() }
    }
  }
#endif
