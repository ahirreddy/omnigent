import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The Tasks tab over the core (web `useSessionTasks` and `TasksPanel`): the session's journal
/// when the server keeps one, else the agent's own task list from the `todos` section, with the
/// core's `tasksView` saying where each task stands. The tab shows while there are tasks of the
/// agent's own or the server keeps journals, as the web's rail does.
enum TasksAdapter {
  /// The phase of a workflow question, which marks only its own task waiting.
  static let workflowQuestionPhase = "workflow_request_input"
  /// The `todos` section's statuses, as its detail titles lead.
  private static let todoStatuses: [(String, NativeTaskStatus)] = [
    ("completed", .completed), ("in progress", .inProgress), ("pending", .pending),
  ]

  /// What the tab needs from the window.
  struct Routes {
    /// Scrolls the chat to a row and flashes it.
    var showRow: @MainActor (String) -> Void
    /// Shows a failure.
    var report: @MainActor (String) -> Void
  }

  /// The agent's own tasks, from the core's `todos` section: each detail keyed by the task, its
  /// title `<Status>: <content>`, its text what the agent says it is doing.
  static func nativeTasks(_ sections: [OmnigentCoreFFI.EventSection]) -> [NativeTask] {
    let details = sections.first { $0.id == "todos" }?.details ?? []
    return details.compactMap { detail in
      let parts = detail.title.split(separator: ":", maxSplits: 1)
      guard parts.count == 2,
        let status = todoStatuses.first(where: { $0.0 == parts[0].lowercased() })?.1
      else { return nil }
      let content = String(parts[1].dropFirst())
      return NativeTask(
        id: detail.id, content: content, status: status,
        activeForm: status == .inProgress ? detail.text : nil)
    }
  }

  /// The task markers in the transcript, by the id the Tasks tab links to, with their rows.
  static func markerRows(_ rows: [OmnigentCoreFFI.Row]) -> [String: String] {
    var found: [String: String] = [:]
    for row in rows {
      guard let activity = row.activity, activity.kind == .taskMarker,
        let marker = activity.details.first(where: { $0.id == "marker" })?.text
      else { continue }
      found[marker] = row.id
    }
    return found
  }

  /// Whether a question or permission prompt in the chat waits for the user, leaving out a
  /// workflow question, which marks only its own task (web `hasPendingOwnElicitation`).
  static func awaitsUser(_ conversation: ConversationStore) -> Bool {
    conversation.decisions.pending.contains { card in
      card.phase != workflowQuestionPhase
        && (card.targetSessionId.isEmpty || card.targetSessionId == conversation.sessionID)
    }
  }

  /// Whether the session's work is in flight: its turn, or a background task (web
  /// `useSessionWorking`).
  static func isWorking(_ conversation: ConversationStore, summary: OmnigentCoreFFI.SessionSummary?)
    -> Bool
  {
    let background =
      conversation.sections.first { $0.id == "status" }?.details
      .first { $0.id == "background" }.flatMap { Int($0.text) } ?? 0
    return conversation.isRunning || background > 0
      || summary.map { $0.status == .running || $0.backgroundWorkRunning } == true
  }

  /// The core's view of the tab, or `nil` when the tab does not show.
  static func view(
    tasks: SessionTasksStore?, supported: Bool, conversation: ConversationStore,
    summary: OmnigentCoreFFI.SessionSummary?
  ) -> TasksView? {
    let native = nativeTasks(conversation.sections)
    guard supported || !native.isEmpty else { return nil }
    let markers = markerRows(conversation.rows).keys.filter { $0.hasPrefix("todo-") }
    var journalRead = true
    if case .failed? = tasks?.journal { journalRead = false }
    let context = TasksContext(
      sessionWorking: isWorking(conversation, summary: summary),
      awaitingUser: awaitsUser(conversation),
      canSend: !ComposerAdapter.isReadOnly(conversation), journalRead: journalRead)
    return tasksView(
      entries: supported ? tasks?.entries ?? [] : [], nativeTasks: native,
      nativeMarkers: Array(markers), context: context)
  }

  /// The tab's content, or `nil` to hide it.
  static func content(
    tasks: SessionTasksStore?, supported: Bool, conversation: ConversationStore,
    summary: OmnigentCoreFFI.SessionSummary?, routes: Routes
  ) -> TasksPanelContent? {
    guard
      let view = view(
        tasks: tasks, supported: supported, conversation: conversation, summary: summary)
    else { return nil }
    let rowsByMarker = markerRows(conversation.rows)
    var content = TasksPanelContent(
      state: state(view, tasks: tasks, supported: supported, rows: rowsByMarker))
    content.taskToShow = tasks?.taskToShow
    content.shown = { tasks?.taskToShow = nil }
    content.retry = { Task { await tasks?.retry() } }
    content.showInChat = routes.showRow
    let send: @MainActor (String) -> Void = { message in
      if let reason = blockedReason(conversation) {
        routes.report(reason)
        return
      }
      Task { await conversation.composer.sendTaskMessage(message) }
    }
    content.perform = { action, row in
      switch action {
      case .stop: send(stopPlanMessage(planName: nil))
      case .run, .resume, .proceed, .retry:
        if let message = taskActionMessage(action: coreAction(action), taskName: row.name) {
          send(message)
        }
      }
    }
    content.stop = { send(stopPlanMessage(planName: nil)) }
    content.continuePlan = { send(continuePlanMessage(planName: view.planName)) }
    return content
  }

  /// How the transcript's task markers link to the tab, while it shows.
  static func markerLinks(
    tasks: SessionTasksStore?, supported: Bool, conversation: ConversationStore,
    summary: OmnigentCoreFFI.SessionSummary?, showTasks: @escaping @MainActor () -> Void
  ) -> TaskMarkerLinks? {
    guard
      let view = view(
        tasks: tasks, supported: supported, conversation: conversation, summary: summary)
    else { return nil }
    return TaskMarkerLinks(taskIDs: Set(view.rows.map(\.id))) { task in
      tasks?.taskToShow = task
      showTasks()
    }
  }

  /// Why a task message cannot go out now (web `blockedReasonFor`).
  static func blockedReason(_ conversation: ConversationStore) -> String? {
    if awaitsUser(conversation) { return "Answer the agent's question first." }
    return ComposerAdapter.availability(conversation).reason
  }

  static func state(
    _ view: TasksView, tasks: SessionTasksStore?, supported: Bool, rows: [String: String]
  ) -> TasksPanelState {
    if supported, let journal = tasks?.journal {
      switch journal {
      case .failed(let error):
        return .failed("Couldn't load the session's tasks. \(error.message)")
      case .idle, .loading:
        // Until the journal is known the tab shows neither list, as on the web.
        return .loading
      case .unsupported, .loaded:
        break
      }
    }
    guard !view.rows.isEmpty else { return .empty }
    return .loaded(list(view, rows: rows))
  }

  static func list(_ view: TasksView, rows: [String: String]) -> TaskListState {
    TaskListState(
      planName: view.planName, updatedAt: view.updatedAt.map(date), summary: view.summary,
      counts: view.counts.map { TaskCountLine(state: state($0.state), text: $0.text) },
      paused: view.paused, canStop: view.canStop, canContinue: view.canContinue,
      fromPlan: view.fromPlan, rows: view.rows.map { row($0, rows: rows) })
  }

  static func row(_ row: TaskRow, rows: [String: String]) -> TaskRowState {
    TaskRowState(
      id: row.id, number: Int(row.number), name: row.name, state: state(row.state),
      stateLabel: row.stateLabel, isNative: row.native, detail: row.detail.map(detail),
      endedAt: row.endedAt.map(date),
      runningSince: row.countsUp ? row.startedAt.map(date) : nil,
      action: zip(row.action, row.actionTitle).map {
        TaskMenuItem(kind: menuAction($0.0), title: $0.1)
      },
      markerRowID: row.markerId.flatMap { rows[$0] }, dependsOn: row.dependsOnNames,
      goal: row.goal,
      history: row.history.map { entry in
        TaskHistoryLine(
          id: entry.id, label: entry.label, state: historyState(entry.status), text: entry.text,
          date: date(entry.createdAt), restarted: entry.restarted)
      })
  }

  private static func zip<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
    guard let first, let second else { return nil }
    return (first, second)
  }

  static func date(_ seconds: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }

  static func detail(_ detail: OmnigentCoreFFI.TaskDetail) -> TaskDetailLine {
    switch detail {
    case .text(let text): .text(text)
    case .cantStart(let failed): .cantStart(failed: failed)
    case .ready(let goal): .ready(goal: goal)
    case .waitingForYou(let text): .waitingForYou(text: text)
    case .started(let started, let text): .started(since: date(started), text: text)
    }
  }

  static func state(_ state: StepState) -> TaskState {
    switch state {
    case .waiting: .waiting
    case .ready: .ready
    case .running: .running
    case .stopped: .stopped
    case .needsInput: .needsInput
    case .done: .done
    case .failed: .failed
    }
  }

  static func historyState(_ status: StepStatus) -> TaskState {
    switch status {
    case .started: .running
    case .done: .done
    case .needsInput: .needsInput
    case .failed: .failed
    }
  }

  static func menuAction(_ action: OmnigentCoreFFI.TaskAction) -> TaskMenuAction {
    switch action {
    case .run: .run
    case .`continue`: .resume
    case .proceed: .proceed
    case .retry: .retry
    case .stop: .stop
    }
  }

  static func coreAction(_ action: TaskMenuAction) -> OmnigentCoreFFI.TaskAction {
    switch action {
    case .run: .run
    case .resume: .`continue`
    case .proceed: .proceed
    case .retry: .retry
    case .stop: .stop
    }
  }
}
