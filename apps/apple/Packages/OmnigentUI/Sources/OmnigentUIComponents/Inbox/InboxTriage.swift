import Foundation

/// Presentation order and stable selection, independent of transport state.
nonisolated enum InboxTriage {
  struct Group {
    let title: String
    let items: [InboxItem]
  }

  static func items(
    _ items: [InboxItem], filter: InboxFilter, search: String, now: Date = .now,
    calendar: Calendar = .current
  ) -> [InboxItem] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let visible = items.filter { item in
      let matchesFilter: Bool
      switch filter {
      case .all: matchesFilter = true
      case .unread: matchesFilter = item.isUnread && !item.isUnresolved
      case .awaiting: matchesFilter = item.isUnresolved
      }
      let text = [
        item.preview, item.sessionTitle, item.agentName, item.executionContext,
        item.decision?.title ?? "", item.comment?.author ?? "", item.comment?.path ?? "",
        item.comment?.body ?? "",
      ]
      .joined(separator: " ")
      return matchesFilter && (query.isEmpty || text.localizedStandardContains(query))
    }
    return groups(visible, now: now, calendar: calendar).flatMap(\.items)
  }

  /// The count pill's description, as the web: "2 approvals · 1 comment · 3 unread".
  static func summary(_ items: [InboxItem]) -> String {
    let requests = items.filter { $0.kind == .approval || $0.kind == .question }.count
    let comments = items.filter { $0.kind == .comment }.count
    let unread = items.filter { $0.kind == .unread }.count
    return [
      requests > 0 ? (requests == 1 ? "1 approval" : "\(requests) approvals") : nil,
      comments > 0 ? (comments == 1 ? "1 comment" : "\(comments) comments") : nil,
      unread > 0 ? "\(unread) unread" : nil,
    ]
    .compactMap { $0 }.joined(separator: " \u{00B7} ")
  }

  /// Newest first under the web's recency headers: "Just now" (five minutes), "Earlier today",
  /// "Yesterday", "This week" (six calendar days back) and "Older".
  static func groups(_ items: [InboxItem], now: Date = .now, calendar: Calendar = .current)
    -> [Group]
  {
    let today = calendar.startOfDay(for: now)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
    let week = calendar.date(byAdding: .day, value: -6, to: today) ?? today
    func title(_ date: Date) -> String {
      if now.timeIntervalSince(date) < 5 * 60 { return "Just now" }
      if date >= today { return "Earlier today" }
      if date >= yesterday { return "Yesterday" }
      if date >= week { return "This week" }
      return "Older"
    }
    var groups: [Group] = []
    // A stable sort keeps same-time items in the adapter's order.
    let sorted = items.enumerated().sorted {
      $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date > $1.element.date
    }
    for item in sorted.map(\.element) {
      let label = title(item.date)
      if let last = groups.last, last.title == label {
        groups[groups.count - 1] = Group(title: label, items: last.items + [item])
      } else {
        groups.append(Group(title: label, items: [item]))
      }
    }
    return groups
  }

  static func selection(_ selected: String?, previous: [InboxItem], current: [InboxItem]) -> String?
  {
    if let retained = current.first(where: { $0.id == selected }) {
      let prior = previous.first { $0.id == selected }
      if prior?.isUnresolved != true || retained.isUnresolved { return retained.id }
    }
    let actionable = current.filter { $0.isUnresolved && !$0.isReadOnly }
    if let prior = previous.first(where: { $0.id == selected }), prior.decision == nil,
      let hydrated = actionable.first(where: { $0.sessionId == prior.sessionId })
    {
      return hydrated.id
    }
    if let selected, let index = previous.firstIndex(where: { $0.id == selected }) {
      let following = previous.dropFirst(index + 1).map(\.id)
      if let next = following.first(where: { id in actionable.contains { $0.id == id } }) {
        return next
      }
    }
    return actionable.first?.id ?? current.first?.id
  }

  static func move(_ selected: String?, by offset: Int, in items: [InboxItem]) -> String? {
    guard !items.isEmpty else { return nil }
    guard let index = items.firstIndex(where: { $0.id == selected }) else { return items.first?.id }
    return items[min(max(index + offset, 0), items.count - 1)].id
  }
}
