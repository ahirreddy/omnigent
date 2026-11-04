import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The Usage page over ``PagesStore``: the report narrowed to the chosen days by the core.
struct UsageAdapter: View {
  let connection: ConnectionStore
  let open: (String) -> Void
  @State private var window = UsageMapping.Window(range: .month, start: nil, end: nil)

  var body: some View {
    if let pages = connection.pages {
      UsageView(
        state: UsageMapping.state(pages.usage, window: window, now: .now), actions: actions(pages)
      )
      .task { await pages.loadUsage() }
    } else {
      ContentUnavailableView("Usage is unavailable", systemImage: "creditcard")
    }
  }

  private func actions(_ pages: PagesStore) -> UsageActions {
    var actions = UsageActions { formatCostUsd(costUsd: $0) }
    actions.setRange = { range, start, end in
      window = UsageMapping.Window(range: range, start: start, end: end)
    }
    actions.openSession = { open($0) }
    actions.retry = { Task { await pages.loadUsage() } }
    return actions
  }
}

/// Maps the usage report to the page's view state.
enum UsageMapping {
  /// The chosen range; custom days are local calendar days.
  struct Window: Equatable {
    var range: UsageRange
    var start: Date?
    var end: Date?
  }

  static func state(_ load: CreationLoad<UsageReport>, window: Window, now: Date) -> UsageViewState
  {
    guard let report = load.value else {
      let loading = if case .failed = load { false } else { true }
      return UsageViewState(isLoading: loading, loadError: load.error?.message)
    }
    let (since, until) = bounds(window, now: now)
    let narrowed = usageWindow(report: report, since: since, until: until)
    return UsageViewState(
      totalText: formatCostUsd(costUsd: narrowed.totalCostUsd),
      daily: narrowed.dailyCosts.map { UsageAmount(label: $0.day, costUSD: $0.costUsd) },
      byHarness: narrowed.byHarness.map { UsageAmount(label: $0.name, costUSD: $0.costUsd) },
      byModel: narrowed.byModel.map { UsageAmount(label: $0.name, costUSD: $0.costUsd) },
      sessions: narrowed.sessions.map(row))
  }

  /// The inclusive `YYYY-MM-DD` days the window covers; `nil` is open-ended.
  static func bounds(_ window: Window, now: Date) -> (String?, String?) {
    let seconds = Int64(now.timeIntervalSince1970)
    if let days = window.range.days {
      return (usageWindowStart(days: UInt32(days), now: seconds), nil)
    }
    guard window.range == .custom, let start = window.start, let end = window.end else {
      return (nil, nil)
    }
    return (localDay(start), localDay(end))
  }

  private static func localDay(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    let pad = { (value: Int?) in (value ?? 1) < 10 ? "0\(value ?? 1)" : "\(value ?? 1)" }
    return "\(parts.year ?? 1970)-\(pad(parts.month))-\(pad(parts.day))"
  }

  private static func row(_ session: SessionUsage) -> UsageSessionRow {
    var model = session.models.first?.model ?? "\u{2014}"
    if session.models.count > 1 { model += " +\(session.models.count - 1)" }
    return UsageSessionRow(
      id: session.id, title: session.title ?? "Untitled", model: model,
      harness: session.harness ?? "\u{2014}",
      updatedAt: Date(timeIntervalSince1970: TimeInterval(session.updatedAt)),
      costUSD: session.costUsd, costText: formatCostUsd(costUsd: session.costUsd))
  }
}
