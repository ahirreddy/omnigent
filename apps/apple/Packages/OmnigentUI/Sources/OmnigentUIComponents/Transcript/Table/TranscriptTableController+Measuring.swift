#if os(macOS)
  import AppKit
  import Observation
  import SwiftUI

  extension TranscriptTableController {
    // MARK: Cells

    /// The text-cell message row `index` shows, or `nil` when the row stays hosted in SwiftUI;
    /// worked out once per content version.
    func textMessage(at index: Int) -> TranscriptTableTextMessage? {
      guard textStyle.isEnabled else { return nil }
      let row = model.rows[index]
      let version = model.version(at: index)
      if let known = textMessages[row.id], known.version == version { return known.message }
      let message = TranscriptTableTextMessage.make(row, ramp: textStyle.ramp)
      textMessages[row.id] = (version, message)
      return message
    }

    /// The kind of cell row `index` shows in.
    func cellKind(at index: Int) -> TranscriptTableCellKind {
      let kind = model.rows[index].kind
      return textMessage(at: index) == nil ? .hosted(kind) : .text(kind)
    }

    /// A cell for row `index` that the table keeps: from the pool, else a new one.
    func keptCell(at index: Int) -> any TranscriptTableCell {
      let kind = cellKind(at: index)
      if let cell = pool.take(id: model.rows[index].id, kind: kind) { return cell }
      cellsMade += 1
      let cell = makeCell(kind)
      cell.idealSizeChanged = { [weak self] in self?.scheduleRemeasure($0) }
      return cell
    }

    func makeCell(_ kind: TranscriptTableCellKind) -> any TranscriptTableCell {
      switch kind {
      case .hosted: TranscriptTableHostingCell.make(environment: environment)
      case .text: TranscriptTableTextCell(style: textStyle)
      }
    }

    /// The cell showing row `index` in the table, if the row is laid out.
    func realizedCell(at index: Int) -> (any TranscriptTableCell)? {
      guard model.rows.indices.contains(index), index < tableView.numberOfRows else { return nil }
      return tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
        as? any TranscriptTableCell
    }

    // MARK: Measuring

    /// Shows row `index` in `cell` and records its height: a text cell's from its text's
    /// TextKit measurement, a hosted one's from a SwiftUI layout.
    /// - Returns: Whether the table has another height for it.
    @discardableResult
    func measure(_ index: Int, with cell: any TranscriptTableCell) -> Bool {
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
      if let cell = realizedCell(at: index), cell.kind == cellKind(at: index) {
        return measure(index, with: cell)
      }
      let cell = keptCell(at: index)
      let changed = measure(index, with: cell)
      pool.park(cell)
      return changed
    }

    /// Measures row `index` in its kind's measuring cell, for a row far from view. A text cell
    /// hands its laid-out text back, so the row's own cell later shows it without laying out.
    func measureAway(_ index: Int) -> Bool {
      let kind = cellKind(at: index)
      let cell = measuringCells[kind] ?? makeCell(kind)
      measuringCells[kind] = cell
      let changed = measure(index, with: cell)
      (cell as? TranscriptTableTextCell)?.releaseContent()
      return changed
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
    func scheduleRemeasure(_ cell: any TranscriptTableCell) {
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
        measurements += 1
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

    // MARK: Text style

    /// Follows the environment and the window's scale for the text cells.
    func syncTextStyle() {
      watchEnvironment()
      let scale = unsafe scrollView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor
      if let scale { textStyleChanged(textStyle.setScale(scale)) }
    }

    /// Follows the transcript's environment: a new text style lays the text cells out again.
    func watchEnvironment() {
      guard !awaitsEnvironment else { return }
      awaitsEnvironment = true
      withObservationTracking {
        _ = environment.values
      } onChange: { [weak self] in
        MainRunLoop.perform {
          MainActor.assumeIsolated { self?.environmentChanged() }
        }
      }
      textStyleChanged(textStyle.refresh())
    }

    func environmentChanged() {
      awaitsEnvironment = false
      watchEnvironment()
    }

    /// The text style changed: rows pick their cells again, and those on screen show and
    /// measure in their new cells.
    func textStyleChanged(_ changed: Bool) {
      guard changed else { return }
      textMessages = [:]
      prewarmed = [:]
      guard tableView.numberOfRows == model.rows.count, model.width > 0 else { return }
      var reloaded = IndexSet()
      var noted = IndexSet()
      tableView.enumerateAvailableRowViews { _, row in
        guard let cell = realizedCell(at: row) else { return }
        if cell.kind != cellKind(at: row) {
          reloaded.insert(row)
        } else if cell is TranscriptTableTextCell, measure(row, with: cell) {
          noted.insert(row)
        }
      }
      if !reloaded.isEmpty {
        withoutAnimation {
          tableView.reloadData(forRowIndexes: reloaded, columnIndexes: IndexSet(integer: 0))
        }
      }
      noteHeights(noted)
    }
  }
#endif
