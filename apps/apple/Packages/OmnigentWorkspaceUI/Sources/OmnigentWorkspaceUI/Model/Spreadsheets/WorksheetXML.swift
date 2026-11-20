import Foundation

/// What a worksheet's cells show, given the workbook's shared strings and styles.
nonisolated struct WorksheetContext {
  let sharedStrings: [String]
  let dateStyles: [Int: ExcelDateStyle]
  let date1904: Bool
}

/// The text element of a cell being read.
nonisolated private enum WorksheetField {
  case value
  case formula
}

/// A worksheet's records (web `sheetTable`): rows with a value, cells placed by their reference,
/// the first rows kept and every row and column counted.
nonisolated final class WorksheetXML: WorkbookXMLReader {
  /// One cell while it is read.
  private struct Cell {
    var reference: String?
    var type: String?
    var style: Int
    var value: String?
    var formula: String?
    var inline: RunText?
    var field: WorksheetField?
  }

  private let context: WorksheetContext
  private(set) var records: [[String]] = []
  private(set) var totalRows = 0
  private(set) var widest = 0
  /// Characters of the kept rows; past the table's budget, rows are only counted.
  private var keptChars = 0
  private var row: [String] = []
  private var rowHasValue = false
  private var nextColumn = 0
  private var cell: Cell?

  init(context: WorksheetContext) {
    self.context = context
  }

  /// The records, or `nil` for a sheet with no values.
  var sheetRecords: SpreadsheetRecords? {
    records.isEmpty
      ? nil
      : SpreadsheetRecords(
        records: records, totalRows: totalRows, totalColumns: widest,
        description: SpreadsheetFormat.xlsx.title)
  }

  override func start(_ name: String, attributes: [String: String]) {
    switch name {
    case "row":
      row = []
      rowHasValue = false
      nextColumn = 0
    case "c":
      cell = Cell(
        reference: attributes["r"], type: attributes["t"],
        style: attributes["s"].flatMap(Int.init) ?? 0)
    case "v" where cell != nil && cell?.value == nil:
      cell?.value = ""
      cell?.field = .value
    case "f" where cell != nil && cell?.formula == nil:
      cell?.formula = ""
      cell?.field = .formula
    case "is" where cell != nil && cell?.inline == nil:
      cell?.inline = RunText()
    default:
      cell?.inline?.start(name)
    }
  }

  override func end(_ name: String) {
    switch name {
    case "row":
      endRow()
    case "c":
      endCell()
    case "v", "f":
      cell?.field = nil
    default:
      cell?.inline?.end(name)
    }
  }

  override func text(_ text: String) {
    guard cell != nil else { return }
    switch cell?.field {
    case .value: cell?.value? += text
    case .formula: cell?.formula? += text
    case nil: cell?.inline?.append(text)
    }
  }

  private func endCell() {
    guard let cell else { return }
    self.cell = nil
    let column = cell.reference.flatMap(ExcelValues.columnIndex) ?? nextColumn
    nextColumn = column + 1
    let text = cellText(cell)
    guard !text.isEmpty else { return }
    // Counted however far right it is; kept only within the column cap.
    rowHasValue = true
    widest = max(widest, column + 1)
    guard column < DataTablePreview.maxColumns else { return }
    if row.count <= column {
      row.append(contentsOf: repeatElement("", count: column - row.count + 1))
    }
    row[column] = text
  }

  private func endRow() {
    // Rows that only carry formatting don't count.
    guard rowHasValue else { return }
    if !records.isEmpty { totalRows += 1 }
    // Rows past the text budget can't be kept; the first past it is, for the table to cut.
    guard records.count <= DataTablePreview.maxRows, keptChars <= DataTablePreview.maxChars
    else { return }
    if !records.isEmpty {
      keptChars += row.reduce(into: 0) { $0 += $1.unicodeScalars.count }
    }
    records.append(row)
  }

  /// A cell's text, as Excel shows it (web `cellText`).
  private func cellText(_ cell: Cell) -> String {
    if cell.type == "inlineStr" { return cell.inline?.text ?? "" }
    let value = cell.value ?? ""
    // A text formula's saved result can be empty; that blank is what Excel shows.
    if cell.type == "str", cell.value != nil { return value }
    if value.isEmpty {
      // A formula the writer saved without computing; show what it would compute.
      return cell.formula.map { $0.isEmpty ? "" : "=\($0)" } ?? ""
    }
    switch cell.type {
    case "s":
      guard let index = Int(value.trimmingCharacters(in: .whitespaces)),
        context.sharedStrings.indices.contains(index)
      else { return "" }
      return context.sharedStrings[index]
    case "b":
      return value == "1" ? "TRUE" : "FALSE"
    case "str", "e", "d":
      return value
    default:
      return numberText(value, style: context.dateStyles[cell.style])
    }
  }

  private func numberText(_ value: String, style: ExcelDateStyle?) -> String {
    if let style, let serial = Double(value.trimmingCharacters(in: .whitespaces)),
      serial.isFinite
    {
      switch style {
      case .elapsed(let format): return ExcelValues.elapsedText(serial, format: format)
      case .time: return ExcelValues.serialText(serial, date1904: context.date1904, timeOnly: true)
      case .date: return ExcelValues.serialText(serial, date1904: context.date1904)
      }
    }
    return SpreadsheetText.excelNumber(value)
  }
}
