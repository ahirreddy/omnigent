#if os(iOS)
  import SwiftUI
  import UIKit

  extension TranscriptCollectionController {
    // MARK: Measuring

    /// A view for row `index` that a cell can show, of the row's kind: from the pool, else a
    /// new one.
    func keptView(at index: Int) -> any TranscriptCollectionRowView {
      let kind = cellKind(at: index)
      if let view = pool.take(id: model.rows[index].id, kind: kind) { return view }
      switch kind {
      case .text: return makeTextView()
      default: return makeHost()
      }
    }

    func makeHost() -> TranscriptCollectionRowHost {
      hostsMade += 1
      let host = TranscriptCollectionRowHost(environment: environment)
      host.heightChanged = { [weak self] host, height in self?.hostLaidOut(host, height: height) }
      return host
    }

    /// The view showing row `index` in a cell on screen.
    func realizedHost(at index: Int) -> (any TranscriptCollectionRowView)? {
      guard model.rows.indices.contains(index), index < itemCount else { return nil }
      let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
      guard let host = (cell as? TranscriptCollectionCell)?.host,
        host.shownID == model.rows[index].id
      else { return nil }
      return host
    }

    /// Shows row `index` in `host` and records its height. A text row that can't draw the row
    /// leaves it to SwiftUI, which measures it instead.
    /// - Returns: Whether the layout has another height for it.
    @discardableResult
    func measure(_ index: Int, with host: any TranscriptCollectionRowView) -> Bool {
      // Before the viewport has a width there is nothing to measure at.
      guard model.width > 0 else { return false }
      let row = model.rows[index]
      host.show(row, version: model.version(at: index), width: model.width)
      guard host.shownID == row.id else {
        if !isConfiguring { reconfigureRealized(index) }
        return measureAway(index)
      }
      let height = host.idealHeight(at: model.width)
      measurements += 1
      return model.record(height, at: index)
    }

    /// Measures row `index` in a view a cell can then show it in: its own, or one parked under
    /// its id for when it comes into view. A settled message drawn as text is measured from its
    /// run's size, its view made only as it shows, by when its drawing has likely arrived; one
    /// measured at another width and not laid out at this one yet measures in its parked view,
    /// whose drawing stands in while the new one is drawn off the main thread.
    func measureKeeping(_ index: Int) -> Bool {
      if let host = realizedHost(at: index), host.kind == cellKind(at: index) {
        return measure(index, with: host)
      }
      if let message = textMessage(at: index) {
        let id = model.rows[index].id
        let measuredWidth = model.heights.measurement(of: id)?.width
        if let measuredWidth, abs(measuredWidth - model.width) >= 0.5,
          !textStyle.isLaidOut(message, width: model.width),
          let view = pool.take(id: id, kind: cellKind(at: index))
        {
          defer { pool.park(view) }
          if view.shownID == id { return measure(index, with: view) }
        }
        return measureText(index, message, draws: true)
      }
      let host = keptView(at: index)
      let changed = measure(index, with: host)
      pool.park(host)
      return changed
    }

    /// Measures row `index`, far from view: a settled message drawn as text from its run's
    /// size, another row in its kind's measuring host.
    func measureAway(_ index: Int) -> Bool {
      if let message = textMessage(at: index) { return measureText(index, message, draws: false) }
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
        if host.kind == cellKind(at: index) {
          measure(index, with: host)
        } else {
          reconfigureRealized(index)
        }
      }
    }

    /// Tells the layout rows' heights changed, keeping the reader in place: at the bottom while
    /// following, else on the row under the viewport's top.
    func noteHeights(_ indexes: IndexSet, proportionally: Bool = false) {
      guard !indexes.isEmpty else { return }
      let anchor = readingAnchor()
      noteHeightsInPlace(indexes)
      if follow.layoutGrew() {
        pinBottom()
      } else {
        restore(anchor, proportionally: proportionally)
      }
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

    func scheduleRemeasure(_ host: any TranscriptCollectionRowView) {
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

    /// A text row's drawing at a new width landed at another height: the row takes it, and the
    /// reader keeps their share of the row they read, as the width change kept it.
    func drawingLanded(_ view: TranscriptCollectionTextView) {
      guard let shown = view.shown, let index = model.index(of: shown.id),
        shown.version == model.version(at: index), abs(shown.width - model.width) < 0.5
      else { return }
      measurements += 1
      if model.record(view.idealHeight(at: model.width), at: index) {
        noteHeights([index], proportionally: true)
      }
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
    /// scrolling, and waits while the list moves, by the reader's hand or its own.
    func schedulePrefetch() {
      prefetchGeneration += 1
      prewarmDeferred = [:]
      let generation = prefetchGeneration
      let offset = collectionView.contentOffset.y
      MainRunLoop.perform(after: Self.prefetchDelay) { [weak self] in
        MainActor.assumeIsolated { self?.prefetch(generation, from: offset) }
      }
    }

    /// One pass of idle measuring, the list at content offset `offset` when the last ended.
    /// While the list moves (a scroll of its own, a follower kept at the end) it waits.
    func prefetch(_ generation: Int, from offset: CGFloat) {
      guard generation == prefetchGeneration, isShown, !follow.isUserScrolling,
        model.width > 0, offsets.count == model.rows.count
      else { return }
      if waitsForStillness(generation, since: offset) { return }
      var cursor = prefetchCursor ?? startingCursor()
      let shown = collectionView.bounds
      let reach = shown.insetBy(dx: 0, dy: -shown.height * Self.prefetchReach)
      let kept = shown.insetBy(dx: 0, dy: -shown.height * Self.keptReach)
      let deadline = CACurrentMediaTime() + Self.prefetchBudget
      var noted = IndexSet()
      prewarmAroundViewport()
      // Measures row `index` if it needs it, unless the prewarm is still building or drawing
      // it: idle measuring goes on past it, to the SwiftUI rows beyond, and comes back to it.
      // `false` once rows are out of reach.
      func visit(_ index: Int) -> Bool {
        let rect = frame(ofRow: index)
        guard rect.maxY >= reach.minY, rect.minY <= reach.maxY else { return false }
        guard model.needsMeasure(at: index) else { return true }
        let isNear = rect.maxY >= kept.minY && rect.minY <= kept.maxY
        if awaitsPrewarm(index, near: isNear) { return true }
        prewarmDeferred[model.rows[index].id] = nil
        if isNear ? measureKeeping(index) : measureAway(index) { noted.insert(index) }
        return true
      }
      let count = model.rows.count
      while CACurrentMediaTime() < deadline, cursor.above >= 0 || cursor.below < count {
        if cursor.below < count { cursor.below = visit(cursor.below) ? cursor.below + 1 : count }
        if cursor.above >= 0 { cursor.above = visit(cursor.above) ? cursor.above - 1 : -1 }
      }
      prefetchCursor = cursor
      // The rows passed for the prewarm, once it has them or patience runs out.
      for id in Array(prewarmDeferred.keys) where CACurrentMediaTime() < deadline {
        guard let index = model.index(of: id), model.needsMeasure(at: index), visit(index) else {
          prewarmDeferred[id] = nil
          continue
        }
      }
      noteHeights(noted)
      let isDone = cursor.above < 0 && cursor.below >= model.rows.count
      guard !isDone || !prewarmDeferred.isEmpty else { return }
      let settled = collectionView.contentOffset.y
      let next: @Sendable () -> Void = { [weak self] in
        MainActor.assumeIsolated { self?.prefetch(generation, from: settled) }
      }
      // Only messages being built ahead are left: they are looked at again a moment later.
      if isDone {
        MainRunLoop.perform(after: Self.prewarmWait, next)
      } else {
        MainRunLoop.perform(next)
      }
    }

    /// Whether the list moved since idle measuring's last pass left it at `offset`: it looks
    /// again a while later.
    func waitsForStillness(_ generation: Int, since offset: CGFloat) -> Bool {
      let now = collectionView.contentOffset.y
      guard abs(now - offset) >= 0.5 else { return false }
      MainRunLoop.perform(after: Self.prefetchDelay) { [weak self] in
        MainActor.assumeIsolated { self?.prefetch(generation, from: now) }
      }
      return true
    }

    func startingCursor() -> (above: Int, below: Int) {
      let range = visibleRange.isEmpty ? (model.rows.count..<model.rows.count) : visibleRange
      return (range.lowerBound - 1, range.upperBound)
    }
  }
#endif
