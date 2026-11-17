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
      // Answers past what this frame measures lay out off the main thread meanwhile, those
      // the reader reaches first first.
      focusPrewarms(
        at: Double(upward ? proposed.y : proposed.y + height), direction: upward ? -1 : 1)
      let farReach = height * Self.prewarmReach
      prewarmAnswers(
        in: upward
          ? NSRect(
            x: 0, y: proposed.y - height * Self.lookahead - farReach, width: model.width,
            height: farReach + height * Self.lookahead)
          : NSRect(
            x: 0, y: proposed.y + height, width: model.width,
            height: height * Self.lookahead + farReach),
        upward: upward)
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
          if measureAhead(index) { noted.insert(index) }
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
      scrollFeed.moved(to: clipView.bounds.minY + insets.top)
      follow.geometryChanged(isNearBottom: isNearBottom)
      checkOlderHistory()
      reportVisibleRows()
      reportFooterViewport()
    }

    /// The reader opened or closed a fold: the rows on screen are measured again once it has
    /// rendered, as a cell's own report of its new size comes only with its next layout.
    func foldChanged() {
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.tableView.enumerateAvailableRowViews { _, row in
            if let cell = self.realizedCell(at: row) { self.scheduleRemeasure(cell) }
          }
        }
      }
    }

    /// Tells the last row's request cards where the viewport is over that row.
    func reportFooterViewport() {
      guard let last = model.rows.indices.last, last < tableView.numberOfRows else {
        tableViewport.setFooter(nil)
        return
      }
      let row = tableView.rect(ofRow: last)
      let visible = NSRect(
        x: 0, y: clipView.bounds.minY + insets.top, width: row.width, height: visibleHeight)
      tableViewport.setFooter(visible.offsetBy(dx: 0, dy: -row.minY))
    }

    func withoutAnimation(_ body: () -> Void) {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        context.allowsImplicitAnimation = false
        body()
      }
    }

    @objc func liveScrollStarted(_ note: Notification) {
      cancelJump()
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
      cancelJump()
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
      pauseCursorRects(isScrolling)
      scrollFeed.phaseChanged(isScrolling)
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
      // A jump measures the rows it lands on first: the table moves the viewport again for
      // heights it is told of while it is moving.
      if abs(offset - clipView.bounds.minY) > clipView.bounds.height {
        let landing = NSRect(
          x: 0, y: offset, width: model.width, height: clipView.bounds.height * 1.5)
        var noted = IndexSet()
        for index in rowsNeedingMeasure(in: landing) where measureKeeping(index) {
          noted.insert(index)
        }
        noteHeightsInPlace(noted)
      }
      let target = min(max(offset, minimumOffset), maximumOffset)
      clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: target))
      scrollView.reflectScrolledClipView(clipView)
      follow.geometryChanged(isNearBottom: isNearBottom)
    }

    /// The row under the viewport's top, and how far into it the top is. `belowHeader` keeps a
    /// reader at the top on the first row under the header instead, for rows that land between
    /// them: a page of older history.
    func readingAnchor(belowHeader: Bool = false) -> ReadingAnchor? {
      guard !model.rows.isEmpty, tableView.numberOfRows == model.rows.count else { return nil }
      let top = clipView.bounds.minY + insets.top
      var row = tableView.row(at: NSPoint(x: 1, y: max(0, top)))
      if belowHeader, row == 0, model.rows.count > 1 { row = 1 }
      guard model.rows.indices.contains(row) else { return nil }
      return ReadingAnchor(id: model.rows[row].id, offset: top - tableView.rect(ofRow: row).minY)
    }

    /// Puts `anchor`'s row back under the viewport's top.
    func restore(_ anchor: ReadingAnchor?) {
      guard let anchor, let index = model.index(of: anchor.id) else { return }
      let offset = tableView.rect(ofRow: index).minY + anchor.offset - insets.top
      guard abs(offset - clipView.bounds.minY) >= 0.5 else { return }
      probe(
        "transcript top row kept", "\(anchor.id) \(Int(clipView.bounds.minY)) -> \(Int(offset))")
      move(to: offset)
    }

    /// Measures the rows from the end up through a viewport and a half, then goes to the end.
    func pinBottom() {
      guard !model.rows.isEmpty else { return }
      cancelJump()
      measureEnd()
      guard abs(clipView.bounds.minY - maximumOffset) >= 0.5 else { return }
      probe("transcript layout scroll", "end, \(follow)")
      move(to: maximumOffset)
    }

    /// Measures the rows from the top down through a viewport and a half, then goes to the top.
    /// The table can move the viewport again as rows it measures on the way change height, so it
    /// goes again until it is there.
    func moveToTop() {
      var covered: CGFloat = 0
      var noted = IndexSet()
      var index = 0
      while index < model.rows.count, covered < clipView.bounds.height * 1.5 {
        if model.needsMeasure(at: index), measureKeeping(index) { noted.insert(index) }
        covered += model.height(at: index)
        index += 1
      }
      noteHeightsInPlace(noted)
      for _ in 0..<3 where clipView.bounds.minY > minimumOffset + 0.5 {
        move(to: minimumOffset)
      }
    }

    /// Measures the rows from the end up through a viewport and a half, where a move to the end
    /// lands.
    func measureEnd() {
      var covered: CGFloat = 0
      var noted = IndexSet()
      var index = model.rows.count - 1
      while index >= 0, covered < clipView.bounds.height * 1.5 {
        if model.needsMeasure(at: index), measureKeeping(index) { noted.insert(index) }
        covered += model.height(at: index)
        index -= 1
      }
      noteHeightsInPlace(noted)
    }

    /// Opening frames the latest user message at the top, so a long answer reads from its start;
    /// a turn that fits keeps following the end. A session waiting on a request opens at the end,
    /// where its card's actions are, as the stack does once its rows arrive after it shows.
    func frameLatestTurn() {
      let awaitsReader = model.rows.last?.showsPendingRequest == true
      guard !isCLI, !awaitsReader, let latest = model.rows.lastIndex(where: \.isUserMessage)
      else {
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

    /// Follows the newest row again from the end; `animated` eases there, as the stack's pill.
    func jumpToLatest(animated: Bool = false) {
      follow.jumpToLatest()
      guard animated, !model.rows.isEmpty else {
        pinBottom()
        return
      }
      measureEnd()
      jump(
        to: { [weak self] in self?.maximumOffset ?? 0 },
        arrived: { [weak self] in self?.pinBottom() })
    }

    /// Scrolls row `id` into view; a row the table does not have yet is shown once it does.
    /// `animated` eases there, as the stack's message keys and rail do.
    func show(_ id: String, at placement: Placement, animated: Bool = false) {
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
      let target: @MainActor () -> CGFloat = { [weak self] in
        guard let self else { return 0 }
        let rect = tableView.rect(ofRow: model.index(of: id) ?? index)
        return switch placement {
        case .top: rect.minY - insets.top
        case .center: rect.midY - insets.top - visibleHeight / 2
        }
      }
      if animated {
        jump(to: target)
      } else {
        cancelJump()
        move(to: target())
      }
      reportVisibleRows()
    }

    /// The bars over the transcript: a toolbar or plan above, the composer below.
    func setInsets(_ edges: EdgeInsets) {
      let next = NSEdgeInsets(top: edges.top, left: 0, bottom: edges.bottom, right: 0)
      guard next.top != insets.top || next.bottom != insets.bottom else { return }
      probe("transcript dock inset", "\(insets.bottom) -> \(next.bottom)")
      let grew = next.bottom > insets.bottom
      let anchor = readingAnchor()
      insets = next
      scrollView.contentInsets = next
      if grew, follow.layoutGrew() { pinBottom() } else { restore(anchor) }
      reportFooterViewport()
    }
  }
#endif
