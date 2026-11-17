#if os(iOS)
  import SwiftUI
  import UIKit

  extension TranscriptCollectionController {
    // MARK: Measuring

    /// A host for `row` that a cell can show: from the pool, else a new one.
    func keptHost(for row: TranscriptTableRow) -> TranscriptCollectionRowHost {
      if let host = pool.take(id: row.id, kind: .hosted(row.kind)) { return host }
      return makeHost()
    }

    func makeHost() -> TranscriptCollectionRowHost {
      hostsMade += 1
      let host = TranscriptCollectionRowHost(environment: environment)
      host.heightChanged = { [weak self] host, height in self?.hostLaidOut(host, height: height) }
      return host
    }

    /// The host showing row `index` in a cell on screen.
    func realizedHost(at index: Int) -> TranscriptCollectionRowHost? {
      guard model.rows.indices.contains(index), index < itemCount else { return nil }
      let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
      guard let host = (cell as? TranscriptCollectionCell)?.host,
        host.shownID == model.rows[index].id
      else { return nil }
      return host
    }

    /// Shows row `index` in `host` and records its height.
    /// - Returns: Whether the layout has another height for it.
    @discardableResult
    func measure(_ index: Int, with host: TranscriptCollectionRowHost) -> Bool {
      // Before the viewport has a width there is nothing to measure at.
      guard model.width > 0 else { return false }
      host.show(model.rows[index], version: model.version(at: index), width: model.width)
      let height = host.idealHeight(at: model.width)
      measurements += 1
      return model.record(height, at: index)
    }

    /// Measures row `index` in a host a cell can then show it in: its own, or one parked under
    /// its id for when it comes into view.
    func measureKeeping(_ index: Int) -> Bool {
      if let host = realizedHost(at: index) { return measure(index, with: host) }
      let host = keptHost(for: model.rows[index])
      let changed = measure(index, with: host)
      pool.park(host)
      return changed
    }

    /// Measures row `index` in its kind's measuring host, for a row far from view.
    func measureAway(_ index: Int) -> Bool {
      let kind = model.rows[index].kind
      let host = measuringHosts[kind] ?? makeHost()
      measuringHosts[kind] = host
      return measure(index, with: host)
    }

    /// Measures the rows whose cells are on screen, at the current width and metrics.
    func measureShownRows() {
      for case let cell as TranscriptCollectionCell in collectionView.visibleCells {
        guard let host = cell.host, let id = host.shownID, let index = model.index(of: id),
          model.needsMeasure(at: index)
        else { continue }
        measure(index, with: host)
      }
    }

    /// Tells the layout rows' heights changed, keeping the reader in place: at the bottom while
    /// following, else on the row under the viewport's top.
    func noteHeights(_ indexes: IndexSet) {
      guard !indexes.isEmpty else { return }
      let anchor = readingAnchor()
      noteHeightsInPlace(indexes)
      if follow.layoutGrew() { pinBottom() } else { restore(anchor) }
    }

    func noteHeightsInPlace(_ indexes: IndexSet) {
      guard let first = indexes.first, offsets.count == model.rows.count else { return }
      offsets.update(from: first) { model.provideHeight(at: $0) }
      layout.invalidateLayout()
    }

    /// A row measured while its cell was made: the layout takes its height on the next pass.
    func noteNextPass(_ index: Int) {
      pendingNotes.insert(index)
      guard !awaitsNotes else { return }
      awaitsNotes = true
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.awaitsNotes = false
          let noted = self.pendingNotes.filteredIndexSet { $0 < self.model.rows.count }
          self.pendingNotes = []
          self.noteHeights(noted)
        }
      }
    }

    /// How many times a host is measured again for one content before its reports are let go,
    /// so a layout that disagrees with its own measurement does not measure it again and again.
    static let remeasureLimit = 2

    /// SwiftUI laid a host's row out at `height`. A row whose content changed size by itself
    /// (a fold opening, an image arriving) is measured again on the next pass.
    func hostLaidOut(_ host: TranscriptCollectionRowHost, height: CGFloat) {
      // Only a row measured for what the host shows; one not measured yet is measured anyway.
      guard let shown = host.shown, let index = model.index(of: shown.id),
        shown.version == model.version(at: index), abs(shown.width - model.width) < 0.5,
        model.heights.isCurrent(shown.id, version: shown.version, width: model.width),
        let measured = model.heights.measurement(of: shown.id),
        abs(height.rounded(.up) - measured.height) >= 1,
        host.remeasures < Self.remeasureLimit
      else { return }
      host.remeasures += 1
      scheduleRemeasure(host)
    }

    func scheduleRemeasure(_ host: TranscriptCollectionRowHost) {
      pendingHosts[ObjectIdentifier(host)] = host
      guard !awaitsRemeasure else { return }
      awaitsRemeasure = true
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated { self?.remeasurePending() }
      }
    }

    func remeasurePending() {
      awaitsRemeasure = false
      let hosts = pendingHosts.values
      pendingHosts = [:]
      var noted = IndexSet()
      for host in hosts {
        guard let shown = host.shown, let index = model.index(of: shown.id),
          shown.version == model.version(at: index), abs(shown.width - model.width) < 0.5
        else { continue }
        measurements += 1
        let before = model.height(at: index)
        let height = host.idealHeight(at: model.width)
        if model.record(height, at: index) { noted.insert(index) }
        remeasured.append("\(shown.id): \(before) -> \(height)")
        if remeasured.count > 16 { remeasured.removeFirst() }
      }
      noteHeights(noted)
    }

    /// The rows from `minY` to `maxY` that need measuring, top to bottom, or bottom to top for
    /// `upward`.
    func rowsNeedingMeasure(from minY: CGFloat, to maxY: CGFloat, upward: Bool = false) -> [Int] {
      let rows = offsets.rows(from: minY, to: maxY).filter {
        model.rows.indices.contains($0) && model.needsMeasure(at: $0)
      }
      return upward ? rows.reversed() : rows
    }

    // MARK: Older history

    func checkOlderHistory() {
      let top = collectionView.contentOffset.y + insets.top
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
      guard !offsets.isEmpty, offsets.count == model.rows.count else { return }
      let top = collectionView.contentOffset.y + insets.top
      let range = offsets.rows(from: top, to: top + visibleHeight)
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
    /// ``prefetchReach`` viewports either way, and the nearest in hosts kept for them, so they
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
        model.width > 0, offsets.count == model.rows.count
      else { return }
      var cursor = prefetchCursor ?? startingCursor()
      let shown = collectionView.bounds
      let reach = shown.insetBy(dx: 0, dy: -shown.height * Self.prefetchReach)
      let kept = shown.insetBy(dx: 0, dy: -shown.height * Self.keptReach)
      let deadline = CACurrentMediaTime() + Self.prefetchBudget
      var noted = IndexSet()
      // Measures row `index` if it needs it; `false` once rows are out of reach.
      func visit(_ index: Int) -> Bool {
        let rect = frame(ofRow: index)
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
