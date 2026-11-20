import SwiftUI

/// An Excel workbook or a Parquet file on the data table, as the web's `SpreadsheetPreview`
/// shows it: a picker of the visible sheets when a workbook has several, each on the CSV table,
/// and what keeps a sheet or the file from showing.
struct SpreadsheetView: View {
  let preview: SpreadsheetPreview
  /// Downloads the whole file, which the messages offer; `nil` hides it.
  let download: (() -> Void)?
  @State private var selection = 0
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    switch preview {
    case .unreadable(let message):
      unavailable("Can\u{2019}t Preview File", symbol: "tablecells.badge.ellipsis", message)
    case .sheets(let sheets) where sheets.isEmpty:
      unavailable("No Sheets", symbol: "tablecells", "This workbook has no sheets.")
    case .sheets(let sheets):
      let shown = sheets[min(max(selection, 0), sheets.count - 1)]
      VStack(spacing: 0) {
        if sheets.count > 1 {
          SheetPicker(sheets: sheets, selection: $selection, compact: sizeClass == .compact)
          Divider()
        }
        if let table = shown.table {
          // A sheet keeps its own sort and filters only while it is shown, as on the web.
          DataTableView(table: table).id(shown.id)
        } else if let message = shown.message {
          unavailable("Can\u{2019}t Preview Sheet", symbol: "tablecells.badge.ellipsis", message)
        } else {
          unavailable("Empty Sheet", symbol: "tablecells", "This sheet is empty.")
        }
      }
    }
  }

  private func unavailable(_ title: String, symbol: String, _ message: String) -> some View {
    ContentUnavailableView {
      Label(title, systemImage: symbol)
    } description: {
      Text(message)
    } actions: {
      if let download {
        Button("Download", systemImage: "arrow.down.circle", action: download)
          .accessibilityIdentifier("workspace.spreadsheet.download")
      }
    }
    .accessibilityIdentifier("workspace.spreadsheet.message")
  }
}

/// The workbook's sheets: a segmented control while they fit, else a pop-up menu, as a phone's
/// narrow bar always uses.
private struct SheetPicker: View {
  let sheets: [SpreadsheetSheet]
  @Binding var selection: Int
  let compact: Bool

  /// The most sheets a segmented control holds before it turns into a menu.
  private static let segmentLimit = 6

  var body: some View {
    HStack {
      if compact || sheets.count > Self.segmentLimit {
        picker.pickerStyle(.menu).fixedSize()
        Spacer(minLength: 0)
      } else {
        picker.pickerStyle(.segmented).labelsHidden().fixedSize()
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .accessibilityIdentifier("workspace.spreadsheet.sheets")
  }

  private var picker: some View {
    Picker("Sheet", selection: $selection) {
      ForEach(sheets) { sheet in
        Text(sheet.name).tag(sheet.id)
      }
    }
  }
}
