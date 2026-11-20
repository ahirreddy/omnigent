import Foundation

/// Find in a data table, as a text view's find bar: the cells holding the query (ignoring case
/// and accents) in the order the table shows them, row by row, and the one found now.
nonisolated public struct DataTableFind: Hashable, Sendable {
  /// One cell holding the query: a row (by index into the table's rows) and a column.
  public struct Match: Hashable, Sendable {
    /// The row, by index into the table's rows.
    public var row: Int
    /// The column's id.
    public var column: Int

    /// A match.
    public init(row: Int, column: Int) {
      self.row = row
      self.column = column
    }
  }

  /// The bar is open.
  public var isShown = false
  /// What to find.
  public var text = ""
  /// The cells holding ``text``, in the table's order.
  public private(set) var matches: [Match] = []
  /// The match found now, by its place in ``matches``.
  public private(set) var current: Int?
  private var matched: Set<Match> = []

  /// A closed find.
  public init() {}

  /// The match found now.
  public var currentMatch: Match? { current.map { matches[$0] } }

  /// "3 of 12", "Not found", or nothing before a query.
  public var status: String? {
    guard !Self.needle(text).isEmpty else { return nil }
    guard let current else { return "Not found" }
    return "\(current + 1) of \(matches.count.formatted())"
  }

  /// Whether `row`'s cell in `column` holds the query.
  public func isMatch(row: Int, column: Int) -> Bool {
    matched.contains(Match(row: row, column: column))
  }

  /// Finds ``text`` in `rows` of `table` (the rows it shows, in its order). The match found now
  /// stays on its cell while that still matches, else the first match is found.
  /// - Parameters:
  ///   - table: The table.
  ///   - rows: The rows shown, by index into its rows.
  public mutating func search(_ table: DataTablePreview, rows: [Int]) {
    let needle = Self.needle(text)
    let previous = currentMatch
    var found: [Match] = []
    if !needle.isEmpty {
      for row in rows {
        for column in table.columns
        where table.cell(row, column.id).range(of: needle, options: Self.options) != nil {
          found.append(Match(row: row, column: column.id))
        }
      }
    }
    matches = found
    matched = Set(found)
    current = found.isEmpty ? nil : (previous.flatMap { found.firstIndex(of: $0) } ?? 0)
  }

  /// Finds the next match, or the previous one, wrapping around the table.
  /// - Parameter forward: The next match, else the previous one.
  public mutating func step(forward: Bool) {
    guard !matches.isEmpty else { return }
    guard let current else {
      self.current = forward ? 0 : matches.count - 1
      return
    }
    self.current = (current + (forward ? 1 : matches.count - 1)) % matches.count
  }

  /// Closes the bar and forgets the matches; the query stays for the next Find.
  public mutating func close() {
    isShown = false
    matches = []
    matched = []
    current = nil
  }

  private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

  private static func needle(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
