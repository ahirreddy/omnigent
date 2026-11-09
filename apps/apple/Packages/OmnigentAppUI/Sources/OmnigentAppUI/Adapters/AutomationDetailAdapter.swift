import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// An automation's page over ``PagesStore``: its settings and run history, read again every
/// half minute while shown so a started run appears.
struct AutomationDetailAdapter: View {
  let pages: PagesStore
  let automation: Automation
  let open: (String) -> Void
  let back: @MainActor () -> Void
  let edit: @MainActor () -> Void

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      AutomationDetailView(
        state: AutomationDetailMapping.state(
          automation, pages: pages, now: context.date, calendar: .current),
        actions: actions)
    }
    .task(id: automation.id) {
      while !Task.isCancelled {
        await pages.loadAutomationRuns(automation.id)
        do {
          try await Task.sleep(for: .seconds(30))
        } catch {
          return  // Cancelled: the page closed.
        }
      }
    }
  }

  var actions: AutomationDetailActions {
    var actions = AutomationDetailActions()
    let id = automation.id
    actions.back = back
    actions.edit = edit
    actions.delete = {
      Task {
        if await pages.deleteAutomation(id) { back() }
      }
    }
    actions.runNow = {
      Task {
        if await pages.runAutomation(id) { await pages.loadAutomationRuns(id) }
      }
    }
    actions.setPaused = { paused in Task { await pages.setAutomationPaused(id, paused) } }
    actions.openSession = { open($0) }
    actions.retry = { Task { await pages.loadAutomationRuns(id) } }
    actions.dismissError = { pages.dismissAutomationError() }
    return actions
  }
}

/// Maps an automation and its runs to its page.
enum AutomationDetailMapping {
  static func state(_ automation: Automation, pages: PagesStore, now: Date, calendar: Calendar)
    -> AutomationDetailState
  {
    let catalog = pages.automationCatalog.value
    var schedule = automation.scheduleText
    if let next = automation.nextRunAt {
      schedule +=
        " \u{00B7} Next run "
        + formatNextRun(nextRunAt: next, now: Int64(now.timeIntervalSince1970))
    }
    var state = AutomationDetailState(
      id: automation.id, name: automation.name, isPaused: automation.state == .paused,
      scheduleText: schedule, prompt: automation.prompt,
      agent: catalog?.agents.first { $0.id == automation.agentId }?.name ?? automation.agentId,
      host: host(automation, catalog: catalog))
    state.isBusy = pages.busyAutomationIDs.contains(automation.id)
    state.actionError = pages.automationError?.message
    let runs = pages.automationRuns[automation.id]
    state.isLoadingRuns = runs == .loading
    state.runsError = runs?.error?.message
    state.runs = (runs?.value ?? []).map { row($0, now: now, calendar: calendar) }
    return state
  }

  /// Where it runs, in the web's words.
  static func host(_ automation: Automation, catalog: OmnigentCoreFFI.CreationCatalog?) -> String {
    if automation.runsInSandbox { return "New Sandbox" }
    guard let id = automation.hostId else { return "Most recently active host" }
    return catalog?.hosts.first { $0.hostId == id }?.name ?? id
  }

  static func row(_ run: AutomationRun, now: Date, calendar: Calendar) -> AutomationRunRow {
    var row = AutomationRunRow(
      id: run.id, indicator: indicator(run),
      timestamp: timestamp(
        Date(timeIntervalSince1970: TimeInterval(run.startedAt)), now: now, calendar: calendar))
    row.duration = run.duration
    row.statusLabel = run.inFlightLabel
    row.failureStage = run.failureStage
    row.failureReason = run.failureReason
    row.sessionID = run.sessionId
    return row
  }

  private static func indicator(_ run: AutomationRun) -> AutomationRunRow.Indicator {
    switch run.status {
    case .failed, .incomplete: .failed
    case .skipped: .skipped
    case .starting, .running: .inFlight
    case .succeeded: run.unread ? .unread : .completed
    case .scheduled, .unknown: .queued
    }
  }

  /// "Today, 8:00 AM", "Yesterday, 2:30 PM", "Jul 26, 8:00 AM", with the year when it differs.
  static func timestamp(_ date: Date, now: Date, calendar: Calendar) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday)
    {
      return "Yesterday, \(time)"
    }
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    let day =
      sameYear
      ? date.formatted(.dateTime.month(.abbreviated).day())
      : date.formatted(.dateTime.month(.abbreviated).day().year())
    return "\(day), \(time)"
  }
}
