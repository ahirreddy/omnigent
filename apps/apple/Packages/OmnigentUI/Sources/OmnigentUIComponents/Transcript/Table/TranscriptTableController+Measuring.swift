#if os(macOS)
  import AppKit
  import SwiftUI

  extension TranscriptTableController {
    // MARK: Measuring

    /// A cell for `row` that the table keeps: from the pool, else a new one.
    func keptCell(for row: TranscriptTableRow) -> TranscriptTableCell {
      if let cell = pool.take(for: row) { return cell }
      cellsMade += 1
      let cell = TranscriptTableCell.make(environment: environment)
      cell.idealSizeChanged = { [weak self] in self?.scheduleRemeasure($0) }
      return cell
    }

    /// The cell showing row `index` in the table, if the row is laid out.
    func realizedCell(at index: Int) -> TranscriptTableCell? {
      guard model.rows.indices.contains(index), index < tableView.numberOfRows else { return nil }
      return tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
        as? TranscriptTableCell
    }

    /// Shows row `index` in `cell` and records its height.
    /// - Returns: Whether the table has another height for it.
    @discardableResult
    func measure(_ index: Int, with cell: TranscriptTableCell) -> Bool {
      // Before the viewport has a width there is nothing to measure at.
      guard model.width > 0 else { return false }
      cell.show(model.rows[index], version: model.version(at: index), width: model.width)
      isMeasuring = true
      let height = cell.idealHeight
      isMeasuring = false
      measurements += 1
      return model.record(height, at: index)
    }

    /// Measures row `index` in a cell the table can then show it in: its own, or one parked
    /// under its id for when it comes into view.
    func measureKeeping(_ index: Int) -> Bool {
      if let cell = realizedCell(at: index) { return measure(index, with: cell) }
      let cell = keptCell(for: model.rows[index])
      let changed = measure(index, with: cell)
      pool.park(cell)
      return changed
    }

    /// Measures row `index` in its kind's measuring cell, for a row far from view.
    func measureAway(_ index: Int) -> Bool {
      let kind = model.rows[index].kind
      let cell = measuringCells[kind] ?? TranscriptTableCell.make(environment: environment)
      measuringCells[kind] = cell
      return measure(index, with: cell)
    }

    /// Tells the table rows' heights changed, keeping the reader in place: at the bottom while
    /// following, else on the row under the viewport's top.
    func noteHeights(_ indexes: IndexSet) {
      guard !indexes.isEmpty else { return }
      let anchor = readingAnchor()
      noteHeightsInPlace(indexes)
      if follow.layoutGrew() { pinBottom() } else { restore(anchor) }
    }

    func noteHeightsInPlace(_ indexes: IndexSet) {
      guard !indexes.isEmpty else { return }
      withoutAnimation { tableView.noteHeightOfRows(withIndexesChanged: indexes) }
    }

    /// A cell's content changed size by itself: measured again on the next pass.
    func scheduleRemeasure(_ cell: TranscriptTableCell) {
      guard !isMeasuring else { return }
      pendingCells[ObjectIdentifier(cell)] = cell
      guard !awaitsRemeasure else { return }
      awaitsRemeasure = true
      MainRunLoop.perform { [weak self] in
        MainActor.assumeIsolated { self?.remeasurePending() }
      }
    }

    func remeasurePending() {
      awaitsRemeasure = false
      let cells = pendingCells.values
      pendingCells = [:]
      var noted = IndexSet()
      for cell in cells {
        guard let shown = cell.shown, let index = model.index(of: shown.id),
          shown.version == model.version(at: index), abs(shown.width - model.width) < 0.5
        else { continue }
        isMeasuring = true
        let height = cell.idealHeight
        isMeasuring = false
        if model.record(height, at: index) { noted.insert(index) }
      }
      noteHeights(noted)
    }

    /// The rows of `rect` that need measuring, top to bottom, or bottom to top for `upward`.
    func rowsNeedingMeasure(in rect: NSRect, upward: Bool = false) -> [Int] {
      let range = tableView.rows(in: rect)
      guard range.length > 0 else { return [] }
      let rows = (range.location..<(range.location + range.length)).filter {
        model.rows.indices.contains($0) && model.needsMeasure(at: $0)
      }
      return upward ? rows.reversed() : rows
    }
  }
#endif
