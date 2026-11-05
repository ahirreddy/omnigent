public import Observation
public import OmnigentCoreFFI

/// One row of a conversation, observed apart from the others. A view that shows a single row
/// (a side-chat tab, its tab title) reads ``row`` and re-renders when that row changes, not for
/// every streamed delta of ``ConversationStore/rows``.
@Observable
public final class RowWatch {
  /// The watched row's id.
  public let rowID: String
  /// The row, or `nil` while the transcript does not have it.
  public private(set) var row: Row?

  init(rowID: String, row: Row?) {
    self.rowID = rowID
    self.row = row
  }

  /// Takes the row as `rows` has it now; a row that did not change notifies nothing.
  func refresh(from rows: [Row]) {
    let current = rows.first { $0.id == rowID }
    if current != row { row = current }
  }
}

/// The row watches a conversation keeps current as its rows change.
struct RowWatches {
  private var watches: [String: RowWatch] = [:]

  /// The watch for `rowID`, made the first time it is asked for.
  /// - Parameters:
  ///   - rowID: The row.
  ///   - rows: The conversation's rows, read only to fill a new watch.
  /// - Returns: The watch.
  mutating func watch(_ rowID: String, rows: () -> [Row]) -> RowWatch {
    if let watch = watches[rowID] { return watch }
    let watch = RowWatch(rowID: rowID, row: rows().first { $0.id == rowID })
    watches[rowID] = watch
    return watch
  }

  /// Refreshes every watch after the rows were replaced.
  func refreshAll(from rows: [Row]) {
    for watch in watches.values { watch.refresh(from: rows) }
  }

  /// Refreshes the watches of the rows `ops` touched.
  func refresh(touchedBy ops: [RowOp], in rows: [Row]) {
    guard !watches.isEmpty else { return }
    var touched = Set<String>()
    for operation in ops {
      switch operation {
      case .insert(_, let row), .update(_, let row): touched.insert(row.id)
      case .remove(let id): touched.insert(id)
      }
    }
    for id in touched { watches[id]?.refresh(from: rows) }
  }
}
