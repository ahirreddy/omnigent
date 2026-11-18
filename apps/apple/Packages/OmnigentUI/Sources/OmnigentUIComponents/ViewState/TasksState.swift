public import Foundation

/// Where a task stands (the core's `StepState`).
nonisolated public enum TaskState: String, Hashable, Sendable {
  /// Waits for the tasks it depends on.
  case waiting
  /// Can start.
  case ready
  /// Running.
  case running
  /// Started, but the session stopped.
  case stopped
  /// Waits for the user.
  case needsInput
  /// Done.
  case done
  /// Failed.
  case failed
}

/// What a task's menu asks the agent.
nonisolated public enum TaskMenuAction: String, Hashable, Sendable {
  /// Run a ready task.
  case run
  /// Continue a stopped task.
  case resume
  /// Go ahead with a task waiting for the user.
  case proceed
  /// Retry a failed task.
  case retry
  /// Stop the workflow while a task runs.
  case stop
}

/// A task's menu item: what it asks and its title.
nonisolated public struct TaskMenuItem: Hashable, Sendable {
  /// What it asks.
  public var kind: TaskMenuAction
  /// "Run", "Continue", "Retry", "Stop".
  public var title: String

  /// An item.
  public init(kind: TaskMenuAction, title: String) {
    self.kind = kind
    self.title = title
  }
}

/// The line under a task's name (the core's `TaskDetail`).
nonisolated public enum TaskDetailLine: Hashable, Sendable {
  /// Plain text.
  case text(String)
  /// "Can't start · A failed".
  case cantStart(failed: String)
  /// "Ready · goal".
  case ready(goal: String?)
  /// "Waiting for you · text".
  case waitingForYou(text: String)
  /// "Started 3m ago · text".
  case started(since: Date, text: String?)
}

/// One status in a task's history.
nonisolated public struct TaskHistoryLine: Hashable, Sendable, Identifiable {
  /// The entry.
  public var id: String
  /// "Started", "Done", "Waiting for you", "Failed".
  public var label: String
  /// What the status was.
  public var state: TaskState
  /// The text the agent gave.
  public var text: String?
  /// When.
  public var date: Date
  /// A new attempt starts here.
  public var restarted: Bool

  /// A history line.
  public init(
    id: String, label: String, state: TaskState, text: String?, date: Date, restarted: Bool
  ) {
    self.id = id
    self.label = label
    self.state = state
    self.text = text
    self.date = date
    self.restarted = restarted
  }
}

/// One task's row in the Tasks tab.
nonisolated public struct TaskRowState: Hashable, Sendable, Identifiable {
  /// The step or task id.
  public var id: String
  /// Its place, from 1.
  public var number: Int
  /// Its name.
  public var name: String
  /// Where it stands.
  public var state: TaskState
  /// What its state reads as.
  public var stateLabel: String
  /// An item of the agent's own list, which has no history.
  public var isNative: Bool
  /// The line under its name.
  public var detail: TaskDetailLine?
  /// When a done or failed task ended.
  public var endedAt: Date?
  /// When its current attempt started; a running task counts up from it.
  public var runningSince: Date?
  /// What its menu offers.
  public var action: TaskMenuItem?
  /// The chat marker it links to, by row id; `nil` when there is none to show.
  public var markerRowID: String?
  /// The tasks it waits on, by name.
  public var dependsOn: [String]
  /// Its goal.
  public var goal: String?
  /// Its statuses, oldest first.
  public var history: [TaskHistoryLine]

  /// A row.
  public init(
    id: String, number: Int, name: String, state: TaskState, stateLabel: String,
    isNative: Bool = false, detail: TaskDetailLine? = nil, endedAt: Date? = nil,
    runningSince: Date? = nil, action: TaskMenuItem? = nil,
    markerRowID: String? = nil, dependsOn: [String] = [], goal: String? = nil,
    history: [TaskHistoryLine] = []
  ) {
    self.id = id
    self.number = number
    self.name = name
    self.state = state
    self.stateLabel = stateLabel
    self.isNative = isNative
    self.detail = detail
    self.endedAt = endedAt
    self.runningSince = runningSince
    self.action = action
    self.markerRowID = markerRowID
    self.dependsOn = dependsOn
    self.goal = goal
    self.history = history
  }
}

/// A count after the tasks' summary: "2 running".
nonisolated public struct TaskCountLine: Hashable, Sendable {
  /// The state counted.
  public var state: TaskState
  /// The text.
  public var text: String

  /// A count.
  public init(state: TaskState, text: String) {
    self.state = state
    self.text = text
  }
}

/// The tasks the tab lists, with their summary.
nonisolated public struct TaskListState: Hashable, Sendable {
  /// The plan's name, the tab's heading.
  public var planName: String?
  /// When the plan or a status last changed.
  public var updatedAt: Date?
  /// "2 of 5 finished".
  public var summary: String
  /// Counts after the summary.
  public var counts: [TaskCountLine]
  /// "Stopped" or "Run ended".
  public var paused: String?
  /// The plan's stop control shows.
  public var canStop: Bool
  /// The plan's play control shows.
  public var canContinue: Bool
  /// The tasks come from a plan, whose tasks say what they wait on.
  public var fromPlan: Bool
  /// The tasks, in order.
  public var rows: [TaskRowState]

  /// A list.
  public init(
    planName: String? = nil, updatedAt: Date? = nil, summary: String,
    counts: [TaskCountLine] = [], paused: String? = nil, canStop: Bool = false,
    canContinue: Bool = false, fromPlan: Bool = false, rows: [TaskRowState]
  ) {
    self.planName = planName
    self.updatedAt = updatedAt
    self.summary = summary
    self.counts = counts
    self.paused = paused
    self.canStop = canStop
    self.canContinue = canContinue
    self.fromPlan = fromPlan
    self.rows = rows
  }
}

/// What the Tasks tab shows.
nonisolated public enum TasksPanelState: Hashable, Sendable {
  /// The journal is being read.
  case loading
  /// The journal could not be read.
  case failed(String)
  /// No tasks yet.
  case empty
  /// The tasks.
  case loaded(TaskListState)
}

/// The Tasks tab's content and what it can ask for.
public struct TasksPanelContent {
  /// What it shows.
  public var state: TasksPanelState
  /// A task to scroll to and flash, from its chat marker; cleared through ``shown``.
  public var taskToShow: String?
  /// Runs a task's menu action.
  public var perform: @MainActor (TaskMenuAction, TaskRowState) -> Void
  /// The plan's stop control.
  public var stop: @MainActor () -> Void
  /// The plan's play control.
  public var continuePlan: @MainActor () -> Void
  /// Scrolls the chat to a task's marker row.
  public var showInChat: @MainActor (String) -> Void
  /// Reads the journal again after a failure.
  public var retry: @MainActor () -> Void
  /// The tab scrolled to ``taskToShow``.
  public var shown: @MainActor () -> Void

  /// Content.
  public init(
    state: TasksPanelState, taskToShow: String? = nil,
    perform: @escaping @MainActor (TaskMenuAction, TaskRowState) -> Void = { _, _ in },
    stop: @escaping @MainActor () -> Void = {},
    continuePlan: @escaping @MainActor () -> Void = {},
    showInChat: @escaping @MainActor (String) -> Void = { _ in },
    retry: @escaping @MainActor () -> Void = {}, shown: @escaping @MainActor () -> Void = {}
  ) {
    self.state = state
    self.taskToShow = taskToShow
    self.perform = perform
    self.stop = stop
    self.continuePlan = continuePlan
    self.showInChat = showInChat
    self.retry = retry
    self.shown = shown
  }
}

/// How the transcript's task markers link to the Tasks tab (the web's `TaskMarkersProvider`).
public struct TaskMarkerLinks {
  /// The tasks the tab lists now; a marker of another links nowhere.
  public var taskIDs: Set<String>
  /// Opens the Tasks tab, at a task when given one.
  public var open: @MainActor (String?) -> Void

  /// Links.
  public init(taskIDs: Set<String>, open: @escaping @MainActor (String?) -> Void) {
    self.taskIDs = taskIDs
    self.open = open
  }
}
