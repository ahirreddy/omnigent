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
      var awaited: [String] = []
      var awaitedAt: [Double] = []
      // Measures row `index` if it needs it: `.next` to go on, `.stop` once rows are out of
      // reach, `.wait` for an answer the prewarm is still laying out.
      func visit(_ index: Int) -> PrefetchStep {
        let rect = tableView.rect(ofRow: index)
        guard rect.maxY >= reach.minY, rect.minY <= reach.maxY else { return .stop }
        guard model.needsMeasure(at: index) else { return .next }
        if let text = answerLaidOutAhead(at: index) {
          awaited.append(text)
          awaitedAt.append(Double(rect.midY))
          return .wait
        }
        let isNear = rect.maxY >= kept.minY && rect.minY <= kept.maxY
        if isNear ? measureKeeping(index) : measureAway(index) { noted.insert(index) }
        return .next
      }
      let count = model.rows.count
      var waits = false
      while CACurrentMediaTime() < deadline, !waits, cursor.above >= 0 || cursor.below < count {
        if cursor.below < count { waits = step(&cursor.below, by: 1, end: count, visit) }
        if !waits, cursor.above >= 0 { waits = step(&cursor.above, by: -1, end: -1, visit) }
      }
      prefetchCursor = cursor
      noteHeights(noted)
      // The reader is still: answers nearest the viewport, either way, go first.
      MessageTextPrewarm.shared.focus(at: Double(shown.midY), direction: 0)
      prewarmAnswers(in: kept)
      MessageTextPrewarm.shared.prioritize(awaited, at: awaitedAt)
      guard cursor.above >= 0 || cursor.below < model.rows.count else { return }
      // An answer being laid out ahead is measured once it is, a moment later.
      MainRunLoop.perform(after: awaited.isEmpty ? 0 : Self.prewarmWait) { [weak self] in
        MainActor.assumeIsolated { self?.prefetch(generation) }
      }
    }

    /// Visits the row at one side of the idle measuring's cursor and moves that side on.
    /// - Returns: Whether it waits there for the prewarm.
    func step(
      _ position: inout Int, by delta: Int, end: Int, _ visit: (Int) -> PrefetchStep
    ) -> Bool {
      switch visit(position) {
      case .next:
        position += delta
        return false
      case .stop:
        position = end
        return false
      case .wait:
        return true
      }
    }

    /// What measuring a row while idle does next.
    enum PrefetchStep {
      case next
      case stop
      case wait
    }

    /// How often idle measuring looks again for an answer the prewarm is laying out, and how
    /// long it waits for one before laying it out itself.
    static let prewarmWait: TimeInterval = 0.03
    static let prewarmPatience: CFTimeInterval = 0.5

    /// The text of row `index` when it is an answer the prewarm lays out and its first run is
    /// not built yet: idle measuring leaves it to the prewarm rather than lay it out here, for
    /// a while.
    func answerLaidOutAhead(at index: Int) -> String? {
      guard MessageTextPrewarm.isEnabled, MessageTextPrewarm.shared.hasContext,
        let message = textMessage(at: index), message.role == .answer,
        let run = message.runs.first, let style = textStyle.style
      else { return nil }
      let math = TranscriptTableTextCell.typesetMath(run.inlineMath, ramp: style.ramp)
      let key = MessageTextDocumentKey(
        text: message.markdown, piece: run.id, style: style, linked: [],
        math: math.keys.sorted())
      let isBuilt =
        MessageTextDocuments.shared.cached(key) != nil
        || MessageTextPrewarm.shared.takeDocument(for: key) != nil
      let id = model.rows[index].id
      let now = CACurrentMediaTime()
      guard !isBuilt else {
        prewarmAwaited = nil
        return nil
      }
      if let awaited = prewarmAwaited, awaited.id == id {
        guard now - awaited.since < Self.prewarmPatience else { return nil }
      } else {
        prewarmAwaited = (id, now)
      }
      return message.markdown
    }

    // MARK: Cursor rects

    /// `omnigent:transcript-cursor-rects paused`: the window stops rebuilding cursor rects at
    /// each step of a reader's scroll, and rebuilds them once it ends.
    static let pausesCursorRects =
      UserDefaults.standard.string(forKey: "omnigent:transcript-cursor-rects") == "paused"

    func pauseCursorRects(_ paused: Bool) {
      guard Self.pausesCursorRects, paused != cursorRectsPaused,
        let window = unsafe scrollView.window
      else { return }
      cursorRectsPaused = paused
      if paused {
        window.disableCursorRects()
      } else {
        window.enableCursorRects()
        window.resetCursorRects()
      }
    }

    // MARK: Prewarm

    /// How many viewports past the measured lookahead a scroll lays answers out ahead.
    static let prewarmReach: CGFloat = 2

    /// Hands the settled answers in `rect` that a text cell draws to the prewarm, each once per
    /// version, at its place, so they lay out off the main thread before they scroll in, nearest
    /// the reader first.
    func prewarmAnswers(in rect: NSRect, upward: Bool = false) {
      guard textStyle.isEnabled, MessageTextPrewarm.isEnabled, tableView.numberOfRows > 0 else {
        return
      }
      let range = tableView.rows(in: rect)
      guard range.length > 0 else { return }
      var indexes = Array(range.location..<(range.location + range.length))
      if upward { indexes.reverse() }
      var texts: [String] = []
      var positions: [Double] = []
      for index in indexes where model.rows.indices.contains(index) {
        let id = model.rows[index].id
        let version = model.version(at: index)
        guard prewarmed[id] != version, let message = textMessage(at: index) else { continue }
        prewarmed[id] = version
        guard message.role == .answer else { continue }
        texts.append(message.markdown)
        positions.append(Double(tableView.rect(ofRow: index).midY))
      }
      MessageTextPrewarm.shared.prioritize(texts, at: positions)
    }

    func startingCursor() -> (above: Int, below: Int) {
      let range = visibleRange.isEmpty ? (model.rows.count..<model.rows.count) : visibleRange
      return (range.lowerBound - 1, range.upperBound)
    }
  }
#endif
