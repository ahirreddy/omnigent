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

    /// Measures rows away from the viewport while the reader is still, nearest first, a few
    /// milliseconds a pass, so later scrolls find their heights known. It starts a while after
    /// rows change or the reader stops scrolling; the transcript's own moves leave it running.
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
      let deadline = CACurrentMediaTime() + Self.prefetchBudget
      var noted = IndexSet()
      while CACurrentMediaTime() < deadline, cursor.above >= 0 || cursor.below < model.rows.count {
        if cursor.below < model.rows.count {
          if model.needsMeasure(at: cursor.below), measureAway(cursor.below) {
            noted.insert(cursor.below)
          }
          cursor.below += 1
        }
        if cursor.above >= 0 {
          if model.needsMeasure(at: cursor.above), measureAway(cursor.above) {
            noted.insert(cursor.above)
          }
          cursor.above -= 1
        }
      }
      prefetchCursor = cursor
      noteHeights(noted)
      guard cursor.above >= 0 || cursor.below < model.rows.count else { return }
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated { self?.prefetch(generation) }
      }
    }

    func startingCursor() -> (above: Int, below: Int) {
      let range = visibleRange.isEmpty ? (model.rows.count..<model.rows.count) : visibleRange
      return (range.lowerBound - 1, range.upperBound)
    }
  }
#endif
