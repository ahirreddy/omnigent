import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// An automation's page over ``PagesStore``: its settings and run history, read again every
/// half minute while shown so a started run appears, with each run's PRs where the server
/// keeps them. One shared with the caller is read-only.
struct AutomationDetailAdapter: View {
  let pages: PagesStore
  let automation: Automation
  let open: (String) -> Void
  let back: @MainActor () -> Void
  let edit: @MainActor () -> Void
  var share: (@MainActor () -> Void)?
  var readsRunsEvery: Duration = .seconds(30)
  @Environment(\.openURL) private var openURL

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
        if AutomationDetailMapping.showsPullRequests(automation, pages: pages) {
          await pages.loadAutomationRunPullRequests(automation.id)
        }
        do {
          try await Task.sleep(for: readsRunsEvery)
        } catch {
          break  // Cancelled: the page closed.
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
    actions.share = share
    actions.openSession = { open($0) }
    actions.openPullRequest = { openURL($0) }
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
    if automation.isTrigger {
      schedule = "Runs when new items match"
    } else if let next = automation.nextRunAt {
      schedule +=
        " \u{00B7} Next run "
        + formatNextRun(nextRunAt: next, now: Int64(now.timeIntervalSince1970))
    }
    let shown = triggerPromptDisplay(prompt: automation.prompt, isTrigger: automation.isTrigger)
    var state = AutomationDetailState(
      id: automation.id, name: automation.name, isPaused: automation.state == .paused,
      scheduleText: schedule, prompt: shown.text,
      agent: catalog?.agents.first { $0.id == automation.agentId }?.name ?? automation.agentId,
      host: host(automation, catalog: catalog))
    state.isTrigger = automation.isTrigger
    state.promptTitle =
      automation.sourceSessionId != nil
      ? "Additional instructions" : (shown.instructionsOnly ? "Instructions" : "Prompt")
    if automation.sharedWithMe {
      state.sharedBy = automation.ownerName
    } else if pages.offered?.automationSharing == true {
      state.canShare = true
      state.shareDisabledReason = ShareAdapter.unavailableReason(pages.offered)
    }
    if let source = automation.sourceSessionId {
      if automation.sharedWithMe {
        state.startsFrom = "Each run starts with a copy of a session the owner chose."
      } else {
        state.startsFrom = "Source session"
        state.startsFromSessionID = source
      }
    }
    state.configuration = configuration(automation, pages: pages, host: state.host)
    if automation.continuesSession, automation.sessionId != nil {
      state.configurationNote =
        "Model, effort, and permission mode are the saved launch settings. The continued session may have changed settings since it started."
    }
    state.isBusy = pages.busyAutomationIDs.contains(automation.id)
    state.actionError = pages.automationError?.message
    let runs = pages.automationRuns[automation.id]
    state.isLoadingRuns = runs == .loading
    state.runsError = runs?.error?.message
    let pullRequests = pages.automationRunPullRequests[automation.id] ?? [:]
    state.runs = (runs?.value ?? []).map {
      row($0, now: now, calendar: calendar, pullRequests: pullRequests[$0.id])
    }
    return state
  }

  /// Each run's PRs show where the server keeps them; a viewer gets no session content.
  static func showsPullRequests(_ automation: Automation, pages: PagesStore) -> Bool {
    pages.offered?.automationRunPullRequests == true && !automation.sharedWithMe
  }

  /// The saved launch settings, in the web's order.
  static func configuration(_ automation: Automation, pages: PagesStore, host: String)
    -> [AutomationConfigField]
  {
    let agent = pages.automationCatalog.value?.agents.first { $0.id == automation.agentId }
    var fields = [
      AutomationConfigField(
        label: "Agent", value: agent?.name ?? automation.agentId),
      AutomationConfigField(label: "Host", value: host),
      AutomationConfigField(label: "Model", value: modelLabel(automation.modelOverride)),
      AutomationConfigField(label: "Effort", value: effortLabel(automation.reasoningEffort)),
      AutomationConfigField(
        label: "Permission mode", value: permissionLabel(automation.permissionMode, agent: agent)),
      AutomationConfigField(
        label: "Session",
        value: automation.continuesSession
          ? "Continue in the same session" : "New session each run"),
      AutomationConfigField(
        label: "Workspace",
        value: automation.workspace
          ?? (automation.runsInSandbox ? "Sandbox default" : "Host home directory")),
    ]
    // The project is the owner's, so a viewer has no name for it.
    if !automation.sharedWithMe,
      automation.projectId != nil || pages.offered?.automationProjects == true
    {
      let name = (pages.automationProjects.value ?? []).first { $0.id == automation.projectId }?
        .name
      fields.append(
        AutomationConfigField(
          label: "Project", value: name ?? automation.projectId ?? "No project"))
    }
    fields.append(AutomationConfigField(label: "Timezone", value: automation.timezone))
    fields.append(
      AutomationConfigField(
        label: "Cost limit per run", value: describeCostLimit(maxCostUsd: automation.maxCostUsd)))
    return fields
  }

  private static func modelLabel(_ model: String?) -> String {
    guard let model, !model.isEmpty else { return "Agent default" }
    return AutomationEditorMapping.claudeModels.first { $0.id == model }?.name ?? model
  }

  private static func effortLabel(_ effort: String?) -> String {
    guard let effort, !effort.isEmpty else { return "Agent default" }
    return AutomationEditorMapping.claudeEfforts.first { $0.id == effort }?.name
      ?? effort.capitalized
  }

  /// The mode's label; outside Claude Code its default choice leaves the CLI as configured.
  private static func permissionLabel(_ mode: String?, agent: OmnigentCoreFFI.CreationAgent?)
    -> String
  {
    guard let mode, !mode.isEmpty else { return "Agent default" }
    if mode == "default", agent?.harnessId != "claude-native" { return "Agent default" }
    let options = agent.flatMap { creationApprovalModeMenu(agent: $0)?.options } ?? []
    return options.first { $0.value == mode }?.title ?? mode
  }

  /// Where it runs, in the web's words; a viewer can't see the owner's hosts.
  static func host(_ automation: Automation, catalog: OmnigentCoreFFI.CreationCatalog?) -> String {
    if automation.runsInSandbox { return "New Sandbox" }
    guard let id = automation.hostId else { return "Most recently active host" }
    if let name = catalog?.hosts.first(where: { $0.hostId == id })?.name { return name }
    return automation.sharedWithMe ? "The owner\u{2019}s host" : id
  }

  static func row(
    _ run: AutomationRun, now: Date, calendar: Calendar, pullRequests: RunPullRequests? = nil
  ) -> AutomationRunRow {
    var row = AutomationRunRow(
      id: run.id, indicator: indicator(run),
      timestamp: timestamp(
        Date(timeIntervalSince1970: TimeInterval(run.startedAt)), now: now, calendar: calendar))
    row.duration = run.duration
    row.statusLabel = run.inFlightLabel ?? (run.sessionRunning ? "Session running" : nil)
    row.failureStage = run.failureStage
    row.failureReason = run.failureReason
    row.errorDetail = run.errorDetail
    row.sessionCost = run.sessionCost
    row.needsApproval = run.needsApproval
    row.sessionID = run.sessionId
    if let pullRequests, !pullRequests.pullRequests.isEmpty {
      row.pullRequestSummary = pullRequests.summary
      row.pullRequests = pullRequests.pullRequests.compactMap { pullRequest in
        URL(string: pullRequest.url).map { url in
          AutomationRunPullRequest(
            url: url, number: pullRequest.number,
            title: pullRequest.title ?? pullRequest.repository,
            status: pullRequest.statusLabel, repository: pullRequest.repository,
            origin: pullRequest.createdByRun ? "Opened by this run" : "Worked on by this run")
        }
      }
    }
    return row
  }

  private static func indicator(_ run: AutomationRun) -> AutomationRunRow.Indicator {
    switch run.status {
    case .failed, .incomplete: .failed
    case .skipped: .skipped
    case .starting, .running: .inFlight
    case .succeeded where run.sessionRunning: .sessionRunning
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
