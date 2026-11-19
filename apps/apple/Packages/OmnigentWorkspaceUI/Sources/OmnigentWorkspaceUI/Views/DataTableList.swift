import SwiftUI

/// An iPhone's rows: each shows its first fields, and opens the whole record.
struct DataTableList: View {
  let table: DataTablePreview
  let shown: [Int]
  @State private var opened: DataTableRow?

  /// Fields after the first that a row shows before "more".
  private static let previewFields = 3

  var body: some View {
    List(shown, id: \.self) { row in
      Button {
        opened = DataTableRow(id: row)
      } label: {
        summary(row)
      }
      .foregroundStyle(.primary)
      .contextMenu { DataTableCopyItems(table: table, row: row, cell: nil) }
    }
    .listStyle(.plain)
    .sheet(item: $opened) { row in
      DataTableRecord(table: table, row: row.id)
    }
  }

  private func summary(_ row: Int) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(EmptyCell.shown(table.cell(row, 0)))
        .font(.body.weight(.medium))
        .lineLimit(2)
      ForEach(table.columns.dropFirst().prefix(Self.previewFields)) { column in
        HStack(alignment: .firstTextBaseline) {
          Text(column.name).foregroundStyle(.secondary)
          Spacer(minLength: 12)
          EmptyCell.text(table.cell(row, column.id))
        }
        .font(.subheadline)
        .lineLimit(1)
      }
      let more = table.columns.count - 1 - Self.previewFields
      if more > 0 {
        Text("\(more.formatted()) more \(more == 1 ? "field" : "fields")")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// How a phone's rows show an empty cell: a dash, so a field doesn't read as missing.
private enum EmptyCell {
  static func shown(_ cell: String) -> String {
    cell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\u{2014}" : cell
  }

  static func text(_ cell: String) -> some View {
    Text(shown(cell))
      .monospacedDigit()
      .foregroundStyle(shown(cell) == cell ? .primary : .tertiary)
  }
}

/// One row's fields, each with its column's name, in a sheet.
private struct DataTableRecord: View {
  let table: DataTablePreview
  let row: Int
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List(table.columns) { column in
        let text = table.cell(row, column.id)
        LabeledContent {
          EmptyCell.text(text).textSelection(.enabled)
        } label: {
          Label(column.name, systemImage: column.type.symbol)
        }
        .contextMenu { DataTableCopyItems(table: table, row: row, cell: text) }
      }
      .navigationTitle("Row \((row + 1).formatted())")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Copy Row", systemImage: "doc.on.doc") {
            WorkspacePlatform.copy(table.rowText(row))
          }
        }
      }
    }
  }
}
