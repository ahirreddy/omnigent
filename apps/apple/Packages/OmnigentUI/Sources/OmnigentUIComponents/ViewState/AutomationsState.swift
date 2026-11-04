import Foundation

/// One automation in the Automations list.
nonisolated public struct AutomationRow: Hashable, Sendable, Identifiable {
  /// Id.
  public var id: String
  /// Name.
  public var name: String
  /// The schedule as text ("Weekdays at 8:00 AM").
  public var scheduleText: String
  /// "in 8 mins", or `nil` when paused or unknown.
  public var nextRunText: String?
  /// Paused automations do not fire.
  public var isPaused: Bool
  /// A write for it is in flight.
  public var isBusy = false
  /// The latest run's session, to open it.
  public var lastRunSessionID: String?

  /// Creates a row.
  public init(
    id: String, name: String, scheduleText: String, nextRunText: String? = nil,
    isPaused: Bool = false
  ) {
    self.id = id
    self.name = name
    self.scheduleText = scheduleText
    self.nextRunText = nextRunText
    self.isPaused = isPaused
  }
}

/// The Automations page filter.
nonisolated public enum AutomationsFilter: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// Every automation.
  case all
  /// Active ones.
  case active
  /// Paused ones.
  case paused

  /// The filter itself.
  public var id: Self { self }

  /// The label.
  public var title: String {
    switch self {
    case .all: "All"
    case .active: "Active"
    case .paused: "Paused"
    }
  }
}

/// The Automations page.
nonisolated public struct AutomationsViewState: Hashable, Sendable {
  /// The rows for the current filter and search, in the page's order.
  public var rows: [AutomationRow]
  /// Whether the caller has any automation at all.
  public var hasAny: Bool
  /// The first read is in flight.
  public var isLoading: Bool
  /// Why the list could not be read.
  public var loadError: String?
  /// Why the last change failed.
  public var actionError: String?

  /// Creates the state.
  public init(
    rows: [AutomationRow], hasAny: Bool, isLoading: Bool = false,
    loadError: String? = nil, actionError: String? = nil
  ) {
    self.rows = rows
    self.hasAny = hasAny
    self.isLoading = isLoading
    self.loadError = loadError
    self.actionError = actionError
  }
}

/// What the Automations page can do. Missing actions hide their controls.
public struct AutomationsActions {
  /// Narrow the list.
  public var filter: (@MainActor (AutomationsFilter, String) -> Void)?
  /// Open the editor for a new automation, optionally prefilled from a suggestion.
  public var create: (@MainActor (AutomationSuggestion?) -> Void)?
  /// Open the editor for an automation.
  public var edit: (@MainActor (String) -> Void)?
  /// Pause or resume.
  public var setPaused: (@MainActor (String, Bool) -> Void)?
  /// Run now.
  public var runNow: (@MainActor (String) -> Void)?
  /// Delete.
  public var delete: (@MainActor (String) -> Void)?
  /// Open the latest run's session.
  public var openSession: (@MainActor (String) -> Void)?
  /// Read the list again.
  public var retry: (@MainActor () -> Void)?
  /// Dismiss the last action error.
  public var dismissError: (@MainActor () -> Void)?

  /// Creates actions.
  public init() {}
}

/// A starting point offered under the list, as the web's Suggestions.
nonisolated public struct AutomationSuggestion: Hashable, Sendable, Identifiable {
  /// Id.
  public var id: String
  /// The chip's title and the automation's name.
  public var title: String
  /// SF Symbol.
  public var systemImage: String
  /// The prompt.
  public var prompt: String
  /// The schedule.
  public var schedule: ScheduleChoice

  /// The web's static suggestions (`components/scheduled/suggestions.ts`).
  public static let all: [Self] = [
    Self(
      id: "follow-up-monitor", title: "Follow-up monitor", systemImage: "calendar.badge.clock",
      prompt:
        "Review recent email and calendar activity every weekday morning. Summarize anything that needs my attention and call out follow-ups I should handle today.",
      schedule: ScheduleChoice(preset: .weekdays)),
    Self(
      id: "pr-sweep", title: "PR sweep", systemImage: "arrow.triangle.pull",
      prompt:
        "List open pull requests waiting on review. Highlight stale PRs that need a nudge and summarize the next action for each one.",
      schedule: ScheduleChoice()),
    Self(
      id: "news-digest", title: "News digest", systemImage: "newspaper",
      prompt:
        "Summarize notable news from the last day. Keep it concise, group related items, and flag anything worth reading more closely.",
      schedule: ScheduleChoice()),
  ]
}

/// The schedule editor's model, mirroring the core's: weekdays count from Monday (0).
nonisolated public struct ScheduleChoice: Hashable, Sendable {
  /// The picker's choice.
  public enum Preset: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// Every hour.
    case hourly
    /// Every day.
    case daily
    /// Monday to Friday.
    case weekdays
    /// Chosen weekdays.
    case weekly
    /// Any frequency with an interval.
    case custom

    /// The preset itself.
    public var id: Self { self }

    /// The label.
    public var title: String {
      switch self {
      case .hourly: "Every hour"
      case .daily: "Every day"
      case .weekdays: "Every weekday"
      case .weekly: "Every week"
      case .custom: "Custom schedule"
      }
    }
  }

  /// A custom schedule's unit.
  public enum Frequency: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// Hours.
    case hourly
    /// Days.
    case daily
    /// Weeks.
    case weekly
    /// Months.
    case monthly
    /// Years.
    case yearly

    /// The unit itself.
    public var id: Self { self }

    /// The label.
    public var title: String {
      switch self {
      case .hourly: "Hours"
      case .daily: "Days"
      case .weekly: "Weeks"
      case .monthly: "Months"
      case .yearly: "Years"
      }
    }
  }

  /// The picker's choice.
  public var preset: Preset
  /// Hour, 0-23.
  public var hour: Int
  /// Minute, 0-59.
  public var minute: Int
  /// Weekly days, Monday = 0.
  public var weekdays: Set<Int>
  /// A custom schedule's unit.
  public var frequency: Frequency
  /// A custom schedule's interval.
  public var interval: Int
  /// Monthly and yearly days of the month.
  public var monthDays: [Int]
  /// The yearly month, 1-12.
  public var month: Int

  /// Creates a choice; the defaults are the web's (every day at 9:00 AM).
  public init(
    preset: Preset = .daily, hour: Int = 9, minute: Int = 0, weekdays: Set<Int> = [0],
    frequency: Frequency = .daily, interval: Int = 1, monthDays: [Int] = [1], month: Int = 1
  ) {
    self.preset = preset
    self.hour = hour
    self.minute = minute
    self.weekdays = weekdays
    self.frequency = frequency
    self.interval = interval
    self.monthDays = monthDays
    self.month = month
  }
}

/// The automation editor's fields.
nonisolated public struct AutomationDraftState: Hashable, Sendable {
  /// Name.
  public var name: String
  /// Prompt.
  public var prompt: String
  /// The chosen agent's id.
  public var agentID: String
  /// The schedule; `nil` keeps a rule the editor cannot show (``keptRule``).
  public var schedule: ScheduleChoice?
  /// A rule kept as it is, described.
  public var keptRule: String?
  /// Continue one session across runs.
  public var continuesSession: Bool

  /// Creates the fields.
  public init(
    name: String = "", prompt: String = "", agentID: String = "",
    schedule: ScheduleChoice? = ScheduleChoice(), keptRule: String? = nil,
    continuesSession: Bool = false
  ) {
    self.name = name
    self.prompt = prompt
    self.agentID = agentID
    self.schedule = schedule
    self.keptRule = keptRule
    self.continuesSession = continuesSession
  }

  /// Whether Save can be pressed.
  public var canSave: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !agentID.isEmpty
  }
}

/// An agent the editor offers.
nonisolated public struct AutomationAgentChoice: Hashable, Sendable, Identifiable {
  /// Id.
  public var id: String
  /// Display name.
  public var name: String

  /// Creates a choice.
  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

/// The editor's context: the agents, what the server supports, and the live summary.
public struct AutomationEditorContext {
  /// Agents to choose from.
  public var agents: [AutomationAgentChoice]
  /// The server can continue one session across runs.
  public var supportsSessionModes: Bool
  /// The schedule as text, from the core.
  public var describe: @MainActor (ScheduleChoice) -> String
  /// Editing an existing automation.
  public var isEditing: Bool
  /// The save is in flight.
  public var isSaving: Bool
  /// Why the save failed.
  public var error: String?

  /// Creates a context.
  public init(
    agents: [AutomationAgentChoice], supportsSessionModes: Bool,
    describe: @escaping @MainActor (ScheduleChoice) -> String, isEditing: Bool = false,
    isSaving: Bool = false, error: String? = nil
  ) {
    self.agents = agents
    self.supportsSessionModes = supportsSessionModes
    self.describe = describe
    self.isEditing = isEditing
    self.isSaving = isSaving
    self.error = error
  }
}
