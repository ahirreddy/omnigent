import SwiftUI

/// A `.csv` or `.tsv` file as a read-only table, as the web's `DataTablePreview` shows it: how
/// many rows and columns it has, what it leaves out, filters on its columns, and its rows, which
/// sort by a column and copy a cell or a row. A system table on a Mac and an iPad; on an iPhone a
/// list of rows, each opening the whole record. Find (the Find menu on a Mac, a search field on
/// iPhone and iPad) marks the cells holding a query and steps through them.
struct DataTableView: View {
  let table: DataTablePreview
  @State private var query: DataTableQuery
  @State private var find = DataTableFind()
  @FocusState private var focusedFilter: Int?
  @FocusState private var findFocused: Bool
  @Environment(\.horizontalSizeClass) private var sizeClass

  init(
    table: DataTablePreview, query: DataTableQuery = DataTableQuery(),
    find: DataTableFind = DataTableFind()
  ) {
    self.table = table
    _query = State(initialValue: query)
    _find = State(initialValue: find)
  }

  var body: some View {
    let shown = query.rows(of: table)
    let compact = sizeClass == .compact
    VStack(spacing: 0) {
      DataTableBar(
        table: table, shownCount: shown.count, compact: compact, query: $query
      ) { focusedFilter = $0 }
      if showsFindBar {
        DataTableFindBar(find: $find, focus: $findFocused, close: closeFind)
      }
      if let note = table.omissionNote {
        Label(note, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .padding(.bottom, 6)
          .accessibilityIdentifier("workspace.table.note")
      }
      ForEach($query.filters) { $filter in
        DataTableFilterRow(
          name: table.columns.first { $0.id == filter.column }?.name ?? "",
          text: $filter.text, focus: $focusedFilter, column: filter.column
        ) { query.removeFilter(filter.column) }
      }
      Divider()
      if compact {
        DataTableList(table: table, shown: shown, find: find)
      } else {
        DataTableGrid(table: table, shown: shown, query: $query, find: find)
      }
    }
    .onChange(of: find.text) { find.search(table, rows: query.rows(of: table)) }
    .onChange(of: query) { find.search(table, rows: query.rows(of: table)) }
    #if os(macOS)
      .focusedValue(
        \.dataTableFind,
        DataTableFindActions(
          show: { showFind() }, next: { stepFind(forward: true) },
          previous: { stepFind(forward: false) }))
    #endif
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace.table")
  }

  /// A Mac shows the bar on Find; iPhone and iPad keep it as the table's search field.
  private var showsFindBar: Bool {
    #if os(macOS)
      find.isShown
    #else
      true
    #endif
  }

  private var closeFind: (() -> Void)? {
    #if os(macOS)
      return {
        find.close()
        findFocused = false
      }
    #else
      return nil
    #endif
  }

  /// Opens the bar with the keyboard in it, finding the query it kept.
  private func showFind() {
    find.isShown = true
    find.search(table, rows: query.rows(of: table))
    findFocused = true
  }

  /// Find Next and Previous open the bar first when it is closed, as a text view's do.
  private func stepFind(forward: Bool) {
    guard find.isShown else {
      showFind()
      return
    }
    find.step(forward: forward)
  }
}

/// The summary over the table, with what filters and (on an iPhone) sorts it.
private struct DataTableBar: View {
  let table: DataTablePreview
  let shownCount: Int
  let compact: Bool
  @Binding var query: DataTableQuery
  let focus: (Int) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Text(table.summary)
        .accessibilityIdentifier("workspace.table.summary")
      if shownCount != table.rows.count {
        Text("\(shownCount.formatted()) matching")
          .foregroundStyle(.tint)
          .accessibilityIdentifier("workspace.table.matching")
      }
      Spacer(minLength: 0)
      // A phone's narrow bar keeps the counts and shows the controls as symbols.
      Group {
        if compact { sortMenu }
        filterMenu
      }
      .labelStyle(BarLabelStyle(iconOnly: compact))
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  private var filterMenu: some View {
    Menu {
      ForEach(table.columns) { column in
        Button {
          query.addFilter(column.id)
          focus(column.id)
        } label: {
          Label(
            column.name.isEmpty ? "column \(column.id + 1)" : column.name,
            systemImage: column.type.symbol)
        }
        .disabled(query.filters.contains { $0.column == column.id })
      }
    } label: {
      Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .fixedSize()
    .help("Show only rows whose cell in a column contains some text")
    .accessibilityIdentifier("workspace.table.add-filter")
  }

  /// An iPhone's list has no headers to click, so a menu picks the column and the direction.
  private var sortMenu: some View {
    Menu {
      Picker("Sort By", selection: sortColumn) {
        Text("File Order").tag(Int?.none)
        ForEach(table.columns) { column in
          Text(column.name).tag(Int?.some(column.id))
        }
      }
      if query.sort != nil {
        Picker("Order", selection: ascending) {
          Label("Ascending", systemImage: "arrow.up").tag(true)
          Label("Descending", systemImage: "arrow.down").tag(false)
        }
      }
    } label: {
      Label("Sort", systemImage: "arrow.up.arrow.down")
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .fixedSize()
    .accessibilityIdentifier("workspace.table.sort")
  }

  private var sortColumn: Binding<Int?> {
    Binding {
      query.sort?.column
    } set: { column in
      query.sort = column.map {
        DataTableQuery.Sort(column: $0, ascending: query.sort?.ascending ?? true)
      }
    }
  }

  private var ascending: Binding<Bool> {
    Binding {
      query.sort?.ascending ?? true
    } set: { ascending in
      query.sort?.ascending = ascending
    }
  }
}

/// The bar's controls: symbol and title, or the symbol alone where the bar is narrow.
private struct BarLabelStyle: LabelStyle {
  let iconOnly: Bool

  @ViewBuilder
  func makeBody(configuration: Configuration) -> some View {
    if iconOnly {
      Label(configuration).labelStyle(.iconOnly)
    } else {
      Label(configuration)
    }
  }
}

/// One filter: the column, "contains", the text, and a button that removes it.
private struct DataTableFilterRow: View {
  let name: String
  @Binding var text: String
  var focus: FocusState<Int?>.Binding
  let column: Int
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Text(name).fontWeight(.medium)
      Text("contains").foregroundStyle(.secondary)
      TextField("Text", text: $text)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .focused(focus, equals: column)
        .frame(maxWidth: 280)
        .accessibilityLabel("Filter \(name)")
        .accessibilityIdentifier("workspace.table.filter-\(column)")
      Button(action: remove) {
        Image(systemName: "minus.circle.fill")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help("Remove this filter")
      .accessibilityLabel("Remove the filter on \(name)")
      Spacer(minLength: 0)
    }
    .font(.callout)
    .lineLimit(1)
    .padding(.horizontal, 10)
    .padding(.bottom, 6)
  }
}

/// A row of the system table, by its index into the table's rows.
struct DataTableRow: Identifiable, Hashable {
  let id: Int
}

/// The order a column's header asks for. The table shows the rows ``DataTableQuery`` sorts, so
/// this only carries the column and direction between the header and the query.
private struct DataTableSort: SortComparator, Hashable {
  let column: Int
  var order: SortOrder

  func compare(_ lhs: DataTableRow, _ rhs: DataTableRow) -> ComparisonResult {
    let result: ComparisonResult =
      lhs.id == rhs.id ? .orderedSame : (lhs.id < rhs.id ? .orderedAscending : .orderedDescending)
    guard order == .reverse, result != .orderedSame else { return result }
    return result == .orderedAscending ? .orderedDescending : .orderedAscending
  }
}

/// The rows in a system table: a column per field, its type after its name, numbers to the
/// right. A header sorts ascending, then descending, then back to file order.
private struct DataTableGrid: View {
  let table: DataTablePreview
  let shown: [Int]
  @Binding var query: DataTableQuery
  let find: DataTableFind
  @State private var selection: Set<Int> = []

  var body: some View {
    ScrollViewReader { proxy in
      Table(shown.map(DataTableRow.init), selection: $selection, sortOrder: sortOrder) {
        TableColumnForEach(table.columns) { column in
          TableColumn(
            Text("\(column.name)  \(Text(column.type.rawValue).foregroundStyle(.secondary))"),
            sortUsing: DataTableSort(column: column.id, order: .forward)
          ) { row in
            DataTableCell(
              table: table, row: row.id, column: column, highlight: highlight(row.id, column))
          }
          .alignment(column.type == .number ? .trailing : .leading)
        }
      }
      #if os(macOS)
        // Copy takes the selected rows, tab-separated, one per line.
        .copyable(selection.isEmpty ? [] : [selectedText])
      #endif
      // The row found now is selected and scrolled into view, as a text view's find does.
      .onChange(of: find.currentMatch) { _, match in
        guard let match else { return }
        selection = [match.row]
        proxy.scrollTo(match.row, anchor: .center)
      }
    }
  }

  private func highlight(_ row: Int, _ column: DataTableColumn) -> DataTableFindHighlight {
    if find.currentMatch == DataTableFind.Match(row: row, column: column.id) { return .current }
    return find.isMatch(row: row, column: column.id) ? .match : .none
  }

  private var selectedText: String {
    selection.sorted().map(table.rowText).joined(separator: "\n")
  }

  private var sortOrder: Binding<[DataTableSort]> {
    Binding {
      query.sort.map {
        [DataTableSort(column: $0.column, order: $0.ascending ? .forward : .reverse)]
      } ?? []
    } set: { order in
      query.request(
        order.first.map { .init(column: $0.column, ascending: $0.order == .forward) })
    }
  }
}

/// One cell: its text on one line, the whole of it on hover, and a menu that copies it or its
/// row.
private struct DataTableCell: View {
  let table: DataTablePreview
  let row: Int
  let column: DataTableColumn
  var highlight = DataTableFindHighlight.none

  var body: some View {
    let text = table.cell(row, column.id)
    Text(text)
      .monospacedDigit()
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(
        maxWidth: .infinity, alignment: column.type == .number ? .trailing : .leading
      )
      .findHighlight(highlight)
      .contentShape(Rectangle())
      .help(text)
      .contextMenu { DataTableCopyItems(table: table, row: row, cell: text) }
  }
}

/// Copy Cell and Copy Row (tab-separated), for a cell's or a row's menu.
struct DataTableCopyItems: View {
  let table: DataTablePreview
  let row: Int
  let cell: String?

  var body: some View {
    if let cell {
      Button("Copy Cell", systemImage: "doc.on.doc") { WorkspacePlatform.copy(cell) }
    }
    Button("Copy Row", systemImage: "doc.on.doc") { WorkspacePlatform.copy(table.rowText(row)) }
  }
}

extension DataColumnType {
  /// The symbol before a column's name.
  var symbol: String {
    switch self {
    case .number: "number"
    case .date: "calendar"
    case .text: "textformat"
    }
  }
}
