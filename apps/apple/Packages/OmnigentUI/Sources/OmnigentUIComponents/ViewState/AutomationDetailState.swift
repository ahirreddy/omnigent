public import Foundation

/// One automation's page: its settings and run history (the web's `/tasks/:id`).
nonisolated public struct AutomationDetailState: Hashable, Sendable {
  /// Id.
  public var id: String
  /// Name.
  public var name: String
  /// Paused automations do not fire.
  public var isPaused: Bool
  /// The schedule and next run ("Weekdays at 8:00 AM · Next run in 8 mins"), or that a
  /// trigger runs when new items match.
  public var scheduleText: String
  /// The prompt each run sends, or a trigger's instructions alone.
  public var prompt: String
  /// The agent's name.
  public var agent: String
  /// Where it runs: a host's name, "New Sandbox" or "Most recently active host".
  public var host: String
  /// "Prompt", "Instructions" for a trigger, or "Additional instructions" from a session.
  public var promptTitle = "Prompt"
  /// It runs when new items match, so it has no Run now.
  public var isTrigger = false
  /// Whose it is, when shared with the caller; the page is then read-only.
  public var sharedBy: String?
  /// The session every run copies, named; `nil` when it doesn't start from one.
  public var startsFrom: String?
  /// That session, to open it; `nil` for a viewer, who can't.
  public var startsFromSessionID: String?
  /// The saved launch settings, in the web's order.
  public var configuration: [AutomationConfigField] = []
  /// Said under the settings, e.g. that a continued session may have changed them.
  public var configurationNote: String?
  /// Share is offered.
  public var canShare = false
  /// Why Share shows disabled.
  public var shareDisabledReason: String?
  /// A write for it is in flight.
  public var isBusy = false
  /// The runs, newest first.
  public var runs: [AutomationRunRow] = []
  /// The first read of the runs is in flight.
  public var isLoadingRuns = false
  /// Why the runs could not be read.
  public var runsError: String?
  /// Why the last change failed.
  public var actionError: String?

  /// The caller only reads it.
  public var isReadOnly: Bool { sharedBy != nil }

  /// Some run shows its session's cost, so the page says what that total is.
  public var showsSessionCostNote: Bool { runs.contains { $0.sessionCost != nil } }

  /// Creates the state.
  public init(
    id: String, name: String, isPaused: Bool, scheduleText: String, prompt: String,
    agent: String, host: String
  ) {
    self.id = id
    self.name = name
    self.isPaused = isPaused
    self.scheduleText = scheduleText
    self.prompt = prompt
    self.agent = agent
    self.host = host
    configuration = [
      AutomationConfigField(label: "Agent", value: agent),
      AutomationConfigField(label: "Host", value: host),
    ]
  }
}

/// One saved launch setting: "Model", "Agent default".
nonisolated public struct AutomationConfigField: Hashable, Sendable, Identifiable {
  /// Label, also the id.
  public var label: String
  /// Value.
  public var value: String

  /// The label.
  public var id: String { label }

  /// Creates a field.
  public init(label: String, value: String) {
    self.label = label
    self.value = value
  }
}

/// One PR a run created or worked on.
nonisolated public struct AutomationRunPullRequest: Hashable, Sendable, Identifiable {
  /// Its page, also the id.
  public var url: URL
  /// "#212".
  public var number: String
  /// Its title, else the repository.
  public var title: String
  /// "Merged", "Closed without merging".
  public var status: String
  /// `owner/repo`.
  public var repository: String
  /// "Opened by this run" or "Worked on by this run".
  public var origin: String

  /// The URL.
  public var id: URL { url }

  /// Creates a PR.
  public init(
    url: URL, number: String, title: String, status: String, repository: String, origin: String
  ) {
    self.url = url
    self.number = number
    self.title = title
    self.status = status
    self.repository = repository
    self.origin = origin
  }
}

/// One run in an automation's history.
nonisolated public struct AutomationRunRow: Hashable, Sendable, Identifiable {
  /// How the run's status icon reads.
  public enum Indicator: Hashable, Sendable {
    /// Failed or incomplete: a warning triangle.
    case failed
    /// Skipped.
    case skipped
    /// Starting or running: a spinner.
    case inFlight
    /// Succeeded, but its session is still working: a spinner.
    case sessionRunning
    /// Succeeded with news the caller hasn't seen.
    case unread
    /// Succeeded and seen.
    case completed
    /// Not started yet.
    case queued
  }

  /// Id.
  public var id: String
  /// The status icon.
  public var indicator: Indicator
  /// When it fired: "Today, 8:00 AM".
  public var timestamp: String
  /// How long it ran ("1m 42s").
  public var duration: String?
  /// "Queued", "Starting", "Running" or "Session running".
  public var statusLabel: String?
  /// Where it stopped ("Host").
  public var failureStage: String?
  /// Why it didn't succeed.
  public var failureReason: String?
  /// The server's description of the failure.
  public var errorDetail: String?
  /// "Session cost $1.23".
  public var sessionCost: String?
  /// Its session waits on an approval or a question.
  public var needsApproval = false
  /// "PR #212 merged", "PRs: 2 merged, 1 closed".
  public var pullRequestSummary: String?
  /// The PRs it created or worked on.
  public var pullRequests: [AutomationRunPullRequest] = []
  /// Its session, to open it.
  public var sessionID: String?
  /// What its agent last wrote about its work, when it follows a plan.
  public var statusText: AutomationRunStatusText?
  /// Its plan's tasks, control and graph; `nil` when it wrote no plan.
  public var tasks: WorkflowRunRowState?
  /// Run now just started it, so it lights up briefly.
  public var isHighlighted = false

  /// Creates a row.
  public init(id: String, indicator: Indicator, timestamp: String) {
    self.id = id
    self.indicator = indicator
    self.timestamp = timestamp
  }
}

/// What a run's agent last wrote: "Done" and "Opened 2 PRs".
nonisolated public struct AutomationRunStatusText: Hashable, Sendable {
  /// The status's label: "Done", "Waiting for you".
  public var label: String
  /// The agent's words.
  public var text: String
  /// A failed task wrote it, which the line shows in the warning color.
  public var isFailure: Bool

  /// Creates a line.
  public init(label: String, text: String, isFailure: Bool) {
    self.label = label
    self.text = text
    self.isFailure = isFailure
  }
}

/// What an automation's page can do. Missing actions hide their controls.
public struct AutomationDetailActions {
  /// Back to the list.
  public var back: (@MainActor () -> Void)?
  /// Open the editor.
  public var edit: (@MainActor () -> Void)?
  /// Delete it.
  public var delete: (@MainActor () -> Void)?
  /// Run it now.
  public var runNow: (@MainActor () -> Void)?
  /// Pause or resume.
  public var setPaused: (@MainActor (Bool) -> Void)?
  /// Share it.
  public var share: (@MainActor () -> Void)?
  /// Open a run's session.
  public var openSession: (@MainActor (String) -> Void)?
  /// Open a run's PR.
  public var openPullRequest: (@MainActor (URL) -> Void)?
  /// What a run's tasks, plan control and graph do: open a task or the workflow, stop or
  /// continue the plan, act on a task.
  public var runTasks = WorkflowDetailActions()
  /// Read the runs again.
  public var retry: (@MainActor () -> Void)?
  /// Dismiss the last action error.
  public var dismissError: (@MainActor () -> Void)?

  /// Creates actions.
  public init() {}
}
