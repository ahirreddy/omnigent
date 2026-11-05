import Foundation

/// One automation's page: its settings and run history (the web's `/tasks/:id`).
nonisolated public struct AutomationDetailState: Hashable, Sendable {
  /// Id.
  public var id: String
  /// Name.
  public var name: String
  /// Paused automations do not fire.
  public var isPaused: Bool
  /// The schedule and next run ("Weekdays at 8:00 AM · Next run in 8 mins").
  public var scheduleText: String
  /// The prompt each run sends.
  public var prompt: String
  /// The agent's name.
  public var agent: String
  /// Where it runs: a host's name, "New Sandbox" or "Most recently active host".
  public var host: String
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
  /// "Queued", "Starting" or "Running".
  public var statusLabel: String?
  /// Where it stopped ("Host").
  public var failureStage: String?
  /// Why it didn't succeed.
  public var failureReason: String?
  /// Its session, to open it.
  public var sessionID: String?

  /// Creates a row.
  public init(id: String, indicator: Indicator, timestamp: String) {
    self.id = id
    self.indicator = indicator
    self.timestamp = timestamp
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
  /// Open a run's session.
  public var openSession: (@MainActor (String) -> Void)?
  /// Read the runs again.
  public var retry: (@MainActor () -> Void)?
  /// Dismiss the last action error.
  public var dismissError: (@MainActor () -> Void)?

  /// Creates actions.
  public init() {}
}
