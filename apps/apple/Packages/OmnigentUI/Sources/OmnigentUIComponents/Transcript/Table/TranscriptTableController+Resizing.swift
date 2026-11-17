#if os(macOS)
  import AppKit
  import SwiftUI

  extension TranscriptTableController {
    // MARK: Resizing

    /// The row under the middle of what the reader sees, and how far down that row the middle
    /// is: a new width puts that point of the row back at the middle, as the stack's reading
    /// anchor does (``TranscriptReadingAnchor``), however the rows above it reflow.
    struct MiddleAnchor: Equatable {
      var id: String
      /// 0 at the row's top, 1 at its bottom.
      var fraction: CGFloat
    }

    /// Where a reader is kept through a change of the rows' width.
    enum WidthAnchor: Equatable {
      /// At the top, where no row lies above.
      case top
      case middle(MiddleAnchor)
    }

    /// The middle of the viewport the bars leave the rows, in the table's coordinates.
    var readingMiddle: CGFloat { clipView.bounds.minY + insets.top + visibleHeight / 2 }

    /// The row under ``readingMiddle`` and how far into it the middle is.
    func middleAnchor() -> MiddleAnchor? {
      guard !model.rows.isEmpty, tableView.numberOfRows == model.rows.count else { return nil }
      let middle = readingMiddle
      let row = tableView.row(at: NSPoint(x: 1, y: max(0, middle)))
      guard model.rows.indices.contains(row) else { return nil }
      let rect = tableView.rect(ofRow: row)
      guard rect.height > 0 else { return nil }
      return MiddleAnchor(id: model.rows[row].id, fraction: (middle - rect.minY) / rect.height)
    }

    /// Where the reader is now, for a width change to keep.
    func widthAnchor() -> WidthAnchor? {
      if clipView.bounds.minY <= minimumOffset + 0.5 { return .top }
      return middleAnchor().map(WidthAnchor.middle)
    }

    /// Puts `anchor`'s point of its row back under the middle. A move measures the rows it
    /// brings into view, which can move the row again, so it moves until the point stays.
    func restore(_ anchor: WidthAnchor?) {
      switch anchor {
      case .top:
        moveToTop()
      case .middle(let middle):
        probe("transcript restore", middle.id)
        measureAround(middle.id)
        for _ in 0..<6 {
          guard let index = model.index(of: middle.id) else { return }
          let rect = tableView.rect(ofRow: index)
          let offset = rect.minY + middle.fraction * rect.height - insets.top - visibleHeight / 2
          guard abs(offset - clipView.bounds.minY) >= 0.5 else { return }
          move(to: offset)
          // Held at an end: nothing nearer to go to.
          if offset < minimumOffset || offset > maximumOffset { return }
        }
      case nil:
        break
      }
    }

    /// Measures the rows a viewport above and below row `id`, where a restore to it lands.
    func measureAround(_ id: String) {
      guard let index = model.index(of: id) else { return }
      var noted = IndexSet()
      var covered: CGFloat = 0
      var row = index
      while row >= 0, covered < visibleHeight {
        if model.needsMeasure(at: row), measureKeeping(row) { noted.insert(row) }
        covered += model.height(at: row)
        row -= 1
      }
      covered = 0
      row = index + 1
      while row < model.rows.count, covered < visibleHeight {
        if model.needsMeasure(at: row), measureKeeping(row) { noted.insert(row) }
        covered += model.height(at: row)
        row += 1
      }
      noteHeightsInPlace(noted)
    }

    /// The viewport is about to take `size`: a new width keeps the reader where they are now.
    func viewportWillResize(to size: NSSize) {
      guard isShown, abs(size.width - clipView.bounds.width) >= 0.5 else { return }
      resizeAnchor = resizeAnchor ?? widthAnchor()
    }

    /// The viewport changed size: rows take a new width, and a follower stays at the end. A
    /// hidden tab's rows keep the width they were shown at until it shows again.
    func viewportResized() {
      guard isShown else { return }
      let anchor = resizeAnchor
      resizeAnchor = nil
      guard syncWidth() else {
        if !frameIfReady(), follow.layoutGrew() { pinBottom() }
        return
      }
      takeWidth(keeping: anchor)
    }

    /// The rows took a new width: those on screen are measured at it now, and the reader is
    /// kept at the end or on their row. The others keep their old heights, or estimates for
    /// it, until they come into view.
    func takeWidth(keeping anchor: WidthAnchor?) {
      var measured = IndexSet()
      tableView.enumerateAvailableRowViews { _, row in
        if let cell = realizedCell(at: row), measure(row, with: cell) { measured.insert(row) }
      }
      probeRowHeights(measured)
      // Every row's height may differ at the new width: the table asks for all of them again.
      withoutAnimation {
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<model.rows.count))
      }
      schedulePrefetch()
      defer { reportFooterViewport() }
      // The frame that shows the new width has the rows' views laid out at it.
      defer {
        tableView.enumerateAvailableRowViews { rowView, _ in rowView.layoutSubtreeIfNeeded() }
      }
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
      probe("transcript width", "\(width), \(follow)")
      return true
    }

    /// The tab hid or shows. Hidden, the transcript takes no width and measures nothing;
    /// shown, it takes the viewport's width in the pass that shows it, keeping the reader
    /// where it hid them.
    func setShown(_ isShown: Bool) {
      guard isShown != self.isShown else {
        if isShown { schedulePrefetch() }
        return
      }
      probe("transcript tab", isShown ? "shown, \(follow)" : "hidden")
      if !isShown {
        hiddenAnchor = widthAnchor()
        self.isShown = false
        return
      }
      self.isShown = true
      let anchor = hiddenAnchor
      hiddenAnchor = nil
      if syncWidth() {
        takeWidth(keeping: anchor)
      } else {
        if follow.layoutGrew(), !isNearBottom { pinBottom() }
        schedulePrefetch()
      }
    }

    /// Records a geometry change for ``LoopProbe``, counted for this transcript alone. `detail`
    /// must hold nothing a conversation says: a loop's line reaches the unified log.
    func probe(_ name: String, _ detail: @autoclosure () -> String) {
      LoopProbe.record(name, tag: probeTag, detail())
    }

    /// Records rows the table was told changed height, in Debug builds, so a loop names them
    /// as the stack's row height probe does.
    func probeRowHeights(_ indexes: IndexSet) {
      #if DEBUG
        for index in indexes where model.rows.indices.contains(index) {
          let id = model.rows[index].id
          HangTrace.pass("row \(id)")
          probe("transcript row height", "\(id) \(model.width)x\(model.height(at: index))")
        }
      #endif
    }
  }
#endif
