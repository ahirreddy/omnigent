public import SwiftUI

/// The goal sheet's state (web `GoalDialog`, `CommandGoalDialog`).
nonisolated public struct GoalSheetState: Hashable, Sendable {
  /// How the session takes a goal.
  public enum Mode: Hashable, Sendable {
    /// Set, pause and clear through the server, with progress; `goal` is the current one.
    case managed(goal: ComposerGoal?)
    /// Started as a `/goal` message to `backend` ("Claude", "Codex").
    case command(backend: String)
  }

  /// The mode.
  public var mode: Mode
  /// A request is in flight.
  public var isBusy: Bool
  /// The latest failure.
  public var errorMessage: String?
  /// The viewer can only read the goal.
  public var isReadOnly: Bool

  /// Creates a state.
  /// - Parameters:
  ///   - mode: Mode.
  ///   - isBusy: Busy.
  ///   - errorMessage: Failure.
  ///   - isReadOnly: Read-only.
  public init(
    mode: Mode, isBusy: Bool = false, errorMessage: String? = nil, isReadOnly: Bool = false
  ) {
    self.mode = mode
    self.isBusy = isBusy
    self.errorMessage = errorMessage
    self.isReadOnly = isReadOnly
  }

  /// The current goal, for a managed goal that has one.
  public var goal: ComposerGoal? {
    if case .managed(let goal) = mode { return goal }
    return nil
  }
}

/// The goal sheet's actions.
public struct GoalSheetActions {
  /// Saves the objective and token cap, or starts the command goal.
  public var submit: @MainActor (String, UInt64?) -> Void
  /// Pauses (`false`) or resumes (`true`) a managed goal.
  public var setActive: (@MainActor (Bool) -> Void)?
  /// Clears a managed goal.
  public var clear: (@MainActor () -> Void)?
  /// Closes the sheet.
  public var dismiss: @MainActor () -> Void

  /// Creates actions.
  /// - Parameters:
  ///   - submit: Save or start.
  ///   - setActive: Pause or resume.
  ///   - clear: Clear.
  ///   - dismiss: Close.
  public init(
    submit: @escaping @MainActor (String, UInt64?) -> Void,
    setActive: (@MainActor (Bool) -> Void)? = nil, clear: (@MainActor () -> Void)? = nil,
    dismiss: @escaping @MainActor () -> Void
  ) {
    self.submit = submit
    self.setActive = setActive
    self.clear = clear
    self.dismiss = dismiss
  }
}

/// Sets, pauses or clears the session's goal, or starts a `/goal` on harnesses that take it as a
/// command.
public struct GoalSheet: View {
  private let state: GoalSheetState
  private let actions: GoalSheetActions
  @State private var objective: String
  @State private var budget: String

  /// Creates the sheet.
  /// - Parameters:
  ///   - state: The state.
  ///   - actions: The actions.
  public init(state: GoalSheetState, actions: GoalSheetActions) {
    self.state = state
    self.actions = actions
    _objective = State(initialValue: state.goal?.objective ?? "")
    _budget = State(initialValue: state.goal?.tokenBudget.map(String.init) ?? "")
  }

  private var tokenBudget: UInt64? {
    UInt64(budget.trimmingCharacters(in: .whitespaces).replacing(",", with: ""))
  }

  private var budgetIsValid: Bool {
    budget.trimmingCharacters(in: .whitespaces).isEmpty || tokenBudget != nil
  }

  private var canSubmit: Bool {
    !state.isBusy && !state.isReadOnly && budgetIsValid
      && !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The sheet.
  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
      Text(title).font(.title3.weight(.semibold))
      Form {
        TextField(fieldTitle, text: $objective, axis: .vertical)
          .lineLimit(2...6)
          .accessibilityIdentifier("goal-objective")
        if case .managed(let goal) = state.mode {
          TextField("Token budget", text: $budget, prompt: Text("No limit"))
            .accessibilityIdentifier("goal-token-budget")
          if let goal {
            LabeledContent("Status", value: goal.status)
            if !goal.usage.isEmpty { LabeledContent("Used", value: goal.usage) }
          }
        }
      }
      .formStyle(.grouped)
      .disabled(state.isReadOnly)
      if let error = state.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.failure)
      }
      buttons
    }
    .padding(Theme.Spacing.extraLarge)
    .frame(minWidth: 420)
    .accessibilityIdentifier("goal-sheet")
  }

  private var title: String {
    switch state.mode {
    case .managed(let goal): goal == nil ? "Set a goal" : "Goal"
    case .command(let backend): "Start a \(backend) goal"
    }
  }

  private var fieldTitle: String {
    if case .command = state.mode { return "Keep working until" }
    return "Objective"
  }

  private var buttons: some View {
    HStack {
      if let goal = state.goal, !state.isReadOnly {
        if let clear = actions.clear {
          Button("Clear Goal", role: .destructive, action: clear).disabled(state.isBusy)
        }
        if let setActive = actions.setActive, goal.canPause || goal.canResume {
          Button(goal.canPause ? "Pause" : "Resume") { setActive(!goal.canPause) }
            .disabled(state.isBusy)
        }
      }
      Spacer()
      if state.isBusy { ProgressView().controlSize(.small) }
      Button("Cancel", role: .cancel, action: actions.dismiss)
        .keyboardShortcut(.cancelAction)
      Button(submitTitle) { actions.submit(objective, tokenBudget) }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)
        .accessibilityIdentifier("goal-submit")
    }
  }

  private var submitTitle: String {
    switch state.mode {
    case .managed(let goal): goal == nil ? "Set Goal" : "Update Goal"
    case .command: "Start Goal"
    }
  }
}
