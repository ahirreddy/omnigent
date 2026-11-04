import SwiftUI

/// Archived sessions grouped by when they last changed, each with Unarchive, and a selection for
/// bulk Unarchive and Delete.
struct ArchivedSessionsPane: View {
  let sessions: [SessionSummary]
  let hasMore: Bool
  let actions: ServerSettingsActions
  @State private var selection: Set<String> = []
  @State private var confirmingDelete = false

  var body: some View {
    if sessions.isEmpty {
      Section { Text("No archived sessions.").foregroundStyle(.secondary) }
    } else {
      Section { bulkBar }
      ForEach(ArchivedGroup.groups(sessions, now: .now), id: \.label) { group in
        Section(group.label) {
          ForEach(group.sessions) { session in row(session) }
        }
      }
      if hasMore, let loadMore = actions.loadMoreArchived {
        Section { Button("Load More", action: loadMore) }
      }
    }
  }

  private var bulkBar: some View {
    HStack {
      SelectionCheck(
        isOn: allSelected, label: selection.isEmpty ? "Select all" : "\(selection.count) selected")
      Spacer()
      Button("Unarchive") { run(actions.unarchive) }
        .disabled(selection.isEmpty || actions.unarchive == nil)
      Button("Delete\u{2026}", role: .destructive) { confirmingDelete = true }
        .disabled(selection.isEmpty || actions.delete == nil)
    }
    .confirmationDialog(
      "Delete \(selection.count) session\(selection.count == 1 ? "" : "s")?",
      isPresented: $confirmingDelete
    ) {
      Button("Delete", role: .destructive) { run(actions.delete) }
    } message: {
      Text("Their history is deleted for everyone. This can't be undone.")
    }
  }

  private func row(_ session: SessionSummary) -> some View {
    HStack {
      SelectionCheck(isOn: selected(session.id), label: nil)
        .accessibilityLabel("Select \(session.title)")
      VStack(alignment: .leading) {
        Text(session.title)
        let detail = [session.agentName, session.workspace].filter { !$0.isEmpty }
        if !detail.isEmpty {
          Text(detail.joined(separator: " \u{00B7} ")).font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
        }
      }
      Spacer()
      if let unarchive = actions.unarchive {
        Button("Unarchive") { unarchive([session.id]) }
      }
    }
  }

  private var allSelected: Binding<Bool> {
    Binding(
      get: { !sessions.isEmpty && selection.count == sessions.count },
      set: { selection = $0 ? Set(sessions.map(\.id)) : [] })
  }

  private func selected(_ id: String) -> Binding<Bool> {
    Binding(
      get: { selection.contains(id) },
      set: { if $0 { selection.insert(id) } else { selection.remove(id) } })
  }

  private func run(_ action: (@MainActor ([String]) -> Void)?) {
    let ids = sessions.map(\.id).filter(selection.contains)
    selection = []
    action?(ids)
  }
}

/// Archived sessions under the web's date labels: Today, Yesterday, Previous 7 days, Previous
/// 30 days, then month and year.
struct ArchivedGroup: Equatable {
  let label: String
  let sessions: [SessionSummary]

  /// Groups `sessions` (newest first) by when they last changed.
  static func groups(
    _ sessions: [SessionSummary], now: Date, calendar: Calendar = .current
  ) -> [Self] {
    var groups: [Self] = []
    for session in sessions {
      let label = label(Date(timeIntervalSince1970: TimeInterval(session.updatedAt)), now, calendar)
      if groups.last?.label == label {
        groups[groups.count - 1] = Self(
          label: label, sessions: groups[groups.count - 1].sessions + [session])
      } else {
        groups.append(Self(label: label, sessions: [session]))
      }
    }
    return groups
  }

  static func label(_ date: Date, _ now: Date, _ calendar: Calendar) -> String {
    let today = calendar.startOfDay(for: now)
    func daysAgo(_ days: Int) -> Date {
      calendar.date(byAdding: .day, value: -days, to: today) ?? today
    }
    if date >= today { return "Today" }
    if date >= daysAgo(1) { return "Yesterday" }
    if date >= daysAgo(7) { return "Previous 7 days" }
    if date >= daysAgo(30) { return "Previous 30 days" }
    return date.formatted(.dateTime.month(.wide).year())
  }
}

/// A selection checkmark for every platform (the checkbox toggle style is macOS only).
private struct SelectionCheck: View {
  @Binding var isOn: Bool
  let label: String?

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      HStack(spacing: Theme.Spacing.small) {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isOn ? Theme.secondary : .secondary)
          .accessibilityHidden(true)
        if let label { Text(label) }
      }
    }
    .buttonStyle(.borderless)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}
