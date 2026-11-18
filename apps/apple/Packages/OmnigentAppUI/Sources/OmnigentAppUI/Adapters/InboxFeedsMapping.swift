import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The Inbox rows of the server's feeds beside the sessions: agent-posted items and automation
/// failures that made no session.
enum InboxFeedsMapping {
  static let suggestionPrefix = "suggestion-"
  static let automationPrefix = "automation-"

  /// The feeds' rows, for a server that offers them.
  static func items(_ connection: ConnectionStore) -> [InboxItem] {
    guard let pages = connection.pages, let offered = pages.offered else { return [] }
    let feeds = pages.feeds
    let choices = inboxDismissOptions().map {
      InboxDismissChoice(id: reasonID($0.reason), title: $0.label)
    }
    var items: [InboxItem] = []
    if offered.inboxItems {
      items += feeds.items.map { suggestion($0, list: connection.sessionList, choices: choices) }
    }
    if offered.automationInbox {
      items += feeds.unreadFailures.map(failure)
    }
    return items
  }

  /// The feeds' loading, paging and failures on the Inbox's state.
  static func apply(_ connection: ConnectionStore, to state: inout InboxViewState) {
    guard let pages = connection.pages, let offered = pages.offered else { return }
    let feeds = pages.feeds
    if offered.inboxItems {
      state.suggestionsFailed = feeds.itemsError != nil
      state.hasMoreSuggestions = feeds.hasMoreItems
      state.isLoadingMoreSuggestions = feeds.isLoadingItems && feeds.itemsLoaded
      state.suggestionWriteFailed = feeds.itemWriteError != nil
      state.unreadSuggestionCount = Int(clamping: feeds.unreadCount)
      state.unreadSuggestionsCapped = feeds.unreadCountCapped
    }
    if offered.automationInbox {
      state.automationsFailed = feeds.failuresError != nil
      state.hasMoreAutomations = feeds.hasMoreFailures
      state.isLoadingMoreAutomations = feeds.isLoadingFailures
    }
  }

  static func suggestion(
    _ record: AgentInboxItemRecord, list: SessionListStore, choices: [InboxDismissChoice]
  ) -> InboxItem {
    let source = list.session(record.sourceSessionId)
    var item = InboxItem(
      id: suggestionPrefix + record.id, kind: .suggestion, sessionId: record.sourceSessionId,
      sessionTitle: record.title, preview: record.preview,
      date: Date(timeIntervalSince1970: TimeInterval(record.createdAt)),
      isUnread: record.isUnread)
    item.agentName = source?.agentName ?? ""
    item.suggestion = InboxSuggestion(
      kindLabel: record.kindLabel, title: record.title, body: record.bodyMd,
      charts: record.charts.map(chart),
      links: record.links.map {
        InboxLink(title: $0.title, sessionID: $0.sessionId, url: $0.webUrl.flatMap(URL.init))
      },
      actions: record.actions.map(\.label),
      sourceTitle: source.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? "its session",
      dismissChoices: choices)
    return item
  }

  static func chart(_ record: InboxChartRecord) -> InboxChart {
    let index = { (label: String?) in label.flatMap { record.labels.firstIndex(of: $0) } }
    var highlight: ClosedRange<Int>?
    if let from = index(record.highlightFrom), let to = index(record.highlightTo) {
      highlight = min(from, to)...max(from, to)
    }
    var markers: [Int: String] = [:]
    for marker in record.markers {
      if let labelIndex = index(marker.at) { markers[labelIndex] = marker.label }
    }
    return InboxChart(
      isBar: record.isBar, title: record.title, labels: record.labels,
      series: record.series.map {
        InboxChart.Series(name: $0.name, values: $0.values, emphasis: $0.emphasis)
      },
      highlight: highlight, markers: markers, source: record.sourceLabel,
      sourceURL: record.sourceUrl.flatMap(URL.init), unit: record.unit)
  }

  static func failure(_ record: AutomationFailureRecord) -> InboxItem {
    var item = InboxItem(
      id: automationPrefix + record.runId, kind: .automationFailure, sessionId: "",
      sessionTitle: record.taskName, preview: record.reason,
      date: Date(timeIntervalSince1970: TimeInterval(record.at)), isUnread: true)
    item.automationFailure = InboxAutomationFailure(
      automationID: record.taskId, name: record.taskName, reason: record.reason)
    return item
  }

  /// The agent-posted item a row shows, if it is one.
  static func suggestionID(_ item: InboxItem) -> String? {
    guard item.kind == .suggestion, item.id.hasPrefix(suggestionPrefix) else { return nil }
    return String(item.id.dropFirst(suggestionPrefix.count))
  }

  /// The failed run a row shows, if it is one.
  static func runID(_ item: InboxItem) -> String? {
    guard item.kind == .automationFailure, item.id.hasPrefix(automationPrefix) else { return nil }
    return String(item.id.dropFirst(automationPrefix.count))
  }

  static func reasonID(_ reason: InboxDismissReason) -> String {
    switch reason {
    case .alreadyDone: "already_done"
    case .useful: "useful"
    case .notRelevant: "not_relevant"
    case .incorrect: "incorrect"
    case .notNow: "not_now"
    }
  }

  static func reason(_ choice: InboxDismissChoice) -> InboxDismissReason? {
    inboxDismissOptions().map(\.reason).first { reasonID($0) == choice.id }
  }
}
