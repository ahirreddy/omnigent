import SwiftUI

/// The Usage page's sessions at iPhone width: one row per session (title, model, harness, last
/// activity and cost) with a sort menu, in place of the wide page's table.
struct UsageSessionList: View {
  let sessions: [UsageSessionRow]
  @Binding var sortOrder: [KeyPathComparator<UsageSessionRow>]
  let openSession: (@MainActor (String) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Picker(
        "Sort by",
        selection: Binding(
          get: { UsageSessionSort(sortOrder) },
          set: { sort in
            let order = sort.order
            if order != sortOrder { sortOrder = order }
          })
      ) {
        ForEach(UsageSessionSort.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("usage-sessions-sort")
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(sessions) { row in
          self.row(row)
          if row.id != sessions.last?.id { Divider() }
        }
      }
      .cardSurface(cornerRadius: Theme.Radius.medium)
    }
    .accessibilityIdentifier("usage-sessions")
  }

  private func row(_ row: UsageSessionRow) -> some View {
    Button {
      openSession?(row.id)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
          Text(row.title).foregroundStyle(.tint).lineLimit(2)
          let updated = Text(row.updatedAt, format: .relative(presentation: .named))
          Text("\(row.model) \u{00B7} \(row.harness) \u{00B7} \(updated)")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        Text(row.costText).monospacedDigit()
      }
      .padding(Theme.Spacing.medium)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(openSession == nil)
  }
}

/// The sort menu's orders, as the table's sortable columns.
enum UsageSessionSort: String, CaseIterable, Identifiable {
  case recent
  case cost
  case title

  var id: Self { self }

  var title: String {
    switch self {
    case .recent: "Last active"
    case .cost: "Cost"
    case .title: "Session"
    }
  }

  /// The table order: newest, costliest, or A to Z first.
  var order: [KeyPathComparator<UsageSessionRow>] {
    switch self {
    case .recent: [KeyPathComparator(\UsageSessionRow.updatedAt, order: .reverse)]
    case .cost: [KeyPathComparator(\UsageSessionRow.costUSD, order: .reverse)]
    case .title: [KeyPathComparator(\UsageSessionRow.title)]
    }
  }

  /// The choice a table order starts with; another column reads as Last active.
  init(_ order: [KeyPathComparator<UsageSessionRow>]) {
    guard let first = order.first else {
      self = .recent
      return
    }
    // The same column in either direction (the wide table can flip it).
    self =
      Self.allCases.first { sort in
        sort.order.contains { column in
          var flipped = column
          flipped.order = first.order
          return flipped == first
        }
      } ?? .recent
  }
}
