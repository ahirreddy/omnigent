import SwiftUI

/// Archived sessions grouped by when they last changed, as the web's Archived section: a
/// retention that marks old ones expired (with Delete expired), a project filter, per-row
/// Unarchive (which opens the session) and Delete, and a selection for bulk Unarchive and Delete.
/// Only the caller's own sessions offer Delete.
struct ArchivedSessionsPane: View {
  let sessions: [SessionSummary]
  let info: [String: ArchivedSessionInfo]
  let projects: [SettingChoice]
  let hasMore: Bool
  let actions: ServerSettingsActions
  @AppStorage(ArchivedRetention.key) private var storedRetention: String?
  @State private var project: String?
  @State private var selection: Set<String> = []
  @State private var pendingDelete: DeleteRequest?

  var body: some View {
    Section { filters }
    if let days = retentionDays, !expired.isEmpty { expiredRow(days) }
    if shown.isEmpty {
      Section { Text("No archived sessions.").foregroundStyle(.secondary) }
    } else {
      Section { bulkBar }
      ForEach(ArchivedGroup.groups(shown, now: .now), id: \.label) { group in
        Section(group.label) {
          ForEach(group.sessions) { session in row(session) }
        }
      }
    }
    if hasMore, let loadMore = actions.loadMoreArchived {
      Section { Button("Load More", action: loadMore) }
    }
  }

  private var retentionDays: Int? { ArchivedRetention.days(storedRetention) }

  /// The project filter, dropped once no loaded session is in it.
  private var shownProject: String? {
    project.flatMap { id in projects.contains { $0.id == id } ? id : nil }
  }

  private var shown: [SessionSummary] {
    guard let shownProject else { return sessions }
    return sessions.filter { info[$0.id]?.projectID == shownProject }
  }

  private var expired: [String] {
    ArchivedRetention.expired(shown, info: info, days: retentionDays, now: .now)
  }

  private func canDelete(_ id: String) -> Bool { info[id]?.canDelete ?? true }

  @ViewBuilder private var filters: some View {
    Picker(
      "Mark as expired after",
      selection: Binding(
        get: { retentionDays },
        set: { days in
          let text = days.map(String.init)
          if storedRetention != text { storedRetention = text }
        })
    ) {
      ForEach(ArchivedRetention.choices, id: \.self) { Text(ArchivedRetention.title($0)).tag($0) }
    }
    .accessibilityIdentifier("settings.archived.retention")
    if !projects.isEmpty {
      Picker("Project", selection: Binding(get: { shownProject }, set: { project = $0 })) {
        Text("All projects").tag(String?.none)
        ForEach(projects) { Text($0.title).tag(Optional($0.id)) }
      }
      .accessibilityIdentifier("settings.archived.project")
    }
  }

  private func expiredRow(_ days: Int) -> some View {
    Section {
      HStack {
        Label(
          "\(count(expired.count)) \(hasMore ? "on loaded pages " : "")past the \(days)-day retention",
          systemImage: "clock.badge.exclamationmark")
        Spacer()
        Button("Delete Expired\u{2026}", role: .destructive) {
          pendingDelete = DeleteRequest(ids: expired)
        }
        .settingsRowButton()
        .disabled(actions.delete == nil)
        .accessibilityIdentifier("settings.archived.delete-expired")
      }
    }
  }

  private var bulkBar: some View {
    let ids = shown.map(\.id).filter(selection.contains)
    let deletable = ids.filter(canDelete)
    return HStack {
      SelectionCheck(
        isOn: allSelected, label: ids.isEmpty ? "Select all" : "\(ids.count) selected")
      Spacer()
      Button("Unarchive") {
        selection = []
        actions.unarchive?(ids)
      }
      .disabled(ids.isEmpty || actions.unarchive == nil)
      Button("Delete\u{2026}", role: .destructive) {
        pendingDelete = DeleteRequest(ids: deletable)
      }
      .disabled(deletable.isEmpty || actions.delete == nil)
      .help(deletable.count < ids.count ? "Only your own sessions can be deleted." : "")
    }
    .settingsRowButton()
    .confirmationDialog(
      pendingDelete.map { "Delete \(count($0.ids.count))?" } ?? "",
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      presenting: pendingDelete
    ) { request in
      Button("Delete", role: .destructive) {
        selection.subtract(request.ids)
        actions.delete?(request.ids)
      }
    } message: { _ in
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
      if actions.unarchive != nil {
        Button("Unarchive") { unarchive(session) }
          .settingsRowButton()
      }
      if canDelete(session.id), actions.delete != nil {
        Button(role: .destructive) {
          pendingDelete = DeleteRequest(ids: [session.id])
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Delete \(session.title)")
      }
    }
    .swipeActions(edge: .trailing) { rowActions(session) }
    .contextMenu { rowActions(session) }
  }

  /// Unarchive and Delete as a touch row's swipe actions and context menu.
  @ViewBuilder private func rowActions(_ session: SessionSummary) -> some View {
    if canDelete(session.id), actions.delete != nil {
      Button("Delete\u{2026}", systemImage: "trash", role: .destructive) {
        pendingDelete = DeleteRequest(ids: [session.id])
      }
    }
    if actions.unarchive != nil {
      Button("Unarchive", systemImage: "tray.and.arrow.up") { unarchive(session) }
    }
  }

  /// Unarchives `session` and opens it.
  private func unarchive(_ session: SessionSummary) {
    actions.unarchive?([session.id])
    actions.openSession?(session.id)
  }

  private var allSelected: Binding<Bool> {
    Binding(
      get: { !shown.isEmpty && shown.allSatisfy { selection.contains($0.id) } },
      set: { selection = $0 ? Set(shown.map(\.id)) : [] })
  }

  private func selected(_ id: String) -> Binding<Bool> {
    Binding(
      get: { selection.contains(id) },
      set: { if $0 { selection.insert(id) } else { selection.remove(id) } })
  }

  private func count(_ sessions: Int) -> String {
    "\(sessions) session\(sessions == 1 ? "" : "s")"
  }
}

/// Sessions waiting for the user to confirm their deletion.
private struct DeleteRequest: Hashable {
  let ids: [String]
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
