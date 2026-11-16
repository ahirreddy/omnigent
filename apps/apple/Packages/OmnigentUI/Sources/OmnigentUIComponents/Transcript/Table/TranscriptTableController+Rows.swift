#if os(macOS)
  import AppKit
  import SwiftUI

  extension TranscriptTableController {
    // MARK: Older history

    func checkOlderHistory() {
      let top = clipView.bounds.minY + insets.top
      guard top < Self.olderHistoryReach else {
        olderRequested = false
        return
      }
      if follow.isUserScrolling || !follow.follows { requestOlder() }
    }

    /// Asks for the page above the loaded rows; the reader stays on the row they were reading
    /// when it lands.
    func requestOlder() {
      guard let state, state.hasMoreHistory, !state.isLoadingHistory, !olderRequested,
        let loadOlder = actions.loadOlder
      else { return }
      olderRequested = true
      loadOlder()
    }

    // MARK: Rows on screen

    func reportVisibleRows() {
      guard !model.rows.isEmpty, tableView.numberOfRows == model.rows.count else { return }
      let visible = NSRect(
        x: 0, y: clipView.bounds.minY + insets.top, width: model.width, height: visibleHeight)
      let rows = tableView.rows(in: visible)
      let range = rows.location..<(rows.location + rows.length)
      guard range != visibleRange else { return }
      visibleRange = range
      guard !awaitsVisibleReport else { return }
      awaitsVisibleReport = true
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.awaitsVisibleReport = false
          self.visibleRowsChanged(self.model.ids, Set(self.visibleRowIDs))
        }
      }
    }

    /// The ids of the rows on screen, top to bottom.
    var visibleRowIDs: [String] {
      visibleRange.filter { model.ids.indices.contains($0) }.map { model.ids[$0] }
    }

    // MARK: Idle measuring

    /// Measures rows around the viewport while the reader is still, nearest first, a few
    /// milliseconds a pass, so the next scrolls find their heights known: out to
    /// ``prefetchReach`` viewports either way, and the nearest in cells kept for them, so they
    /// show without rendering again. It starts a while after rows change or the reader stops
    /// scrolling; the transcript's own moves leave it running.
    func schedulePrefetch() {
      prefetchGeneration += 1
      let generation = prefetchGeneration
      MainRunLoop.perform(after: Self.prefetchDelay) { [weak self] in
        MainActor.assumeIsolated { self?.prefetch(generation) }
      }
    }

    func prefetch(_ generation: Int) {
      guard generation == prefetchGeneration, isShown, !follow.isUserScrolling,
        model.width > 0, tableView.numberOfRows == model.rows.count
      else { return }
      var cursor = prefetchCursor ?? startingCursor()
      let shown = clipView.bounds
      let reach = shown.insetBy(dx: 0, dy: -shown.height * Self.prefetchReach)
      let kept = shown.insetBy(dx: 0, dy: -shown.height * Self.keptReach)
      let deadline = CACurrentMediaTime() + Self.prefetchBudget
      var noted = IndexSet()
      // Measures row `index` if it needs it; `false` once rows are out of reach.
      func visit(_ index: Int) -> Bool {
        let rect = tableView.rect(ofRow: index)
        guard rect.maxY >= reach.minY, rect.minY <= reach.maxY else { return false }
        guard model.needsMeasure(at: index) else { return true }
        let isNear = rect.maxY >= kept.minY && rect.minY <= kept.maxY
        if isNear ? measureKeeping(index) : measureAway(index) { noted.insert(index) }
        return true
      }
      let count = model.rows.count
      while CACurrentMediaTime() < deadline, cursor.above >= 0 || cursor.below < count {
        if cursor.below < count { cursor.below = visit(cursor.below) ? cursor.below + 1 : count }
        if cursor.above >= 0 { cursor.above = visit(cursor.above) ? cursor.above - 1 : -1 }
      }
      prefetchCursor = cursor
      noteHeights(noted)
      prewarmAnswers(in: kept)
      guard cursor.above >= 0 || cursor.below < model.rows.count else { return }
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated { self?.prefetch(generation) }
      }
    }

    // MARK: Prewarm

    /// How many viewports past the measured lookahead a scroll lays answers out ahead.
    static let prewarmReach: CGFloat = 2

    /// Hands the settled answers in `rect` that a text cell draws to the prewarm, nearest the
    /// viewport first, so they lay out off the main thread before they scroll in.
    func prewarmAnswers(in rect: NSRect, upward: Bool = false) {
      guard textStyle.isEnabled, MessageTextPrewarm.isEnabled, tableView.numberOfRows > 0 else {
        return
      }
      let range = tableView.rows(in: rect)
      guard range.length > 0 else { return }
      var indexes = Array(range.location..<(range.location + range.length))
      if upward { indexes.reverse() }
      var texts: [String] = []
      for index in indexes where model.rows.indices.contains(index) {
        let id = model.rows[index].id
        let version = model.version(at: index)
        guard prewarmed[id] != version, let message = textMessage(at: index) else { continue }
        prewarmed[id] = version
        if message.role == .answer { texts.append(message.markdown) }
      }
      MessageTextPrewarm.shared.prioritize(texts)
    }

    func startingCursor() -> (above: Int, below: Int) {
      let range = visibleRange.isEmpty ? (model.rows.count..<model.rows.count) : visibleRange
      return (range.lowerBound - 1, range.upperBound)
    }
  }
#endif
