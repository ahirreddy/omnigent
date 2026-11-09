#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The goal sheet. Its last buttons, in order: Clear, Pause or Resume, Cancel, then submit
  /// while it can be pressed: a disabled button isn't in `buttons`.
  @Suite("Composer: goal sheet", .serialized)
  @MainActor
  struct ComposerGoalSheetTests {
    private final class Log {
      var events: [String] = []
    }
    private let log = Log()

    private func open(_ state: GoalSheetState) -> OffscreenWindow<GoalSheet> {
      let log = log
      return OffscreenWindow(
        GoalSheet(
          state: state,
          actions: GoalSheetActions(
            submit: { log.events.append("submit:\($0):\($1.map(String.init) ?? "none")") },
            setActive: { log.events.append("active:\($0)") },
            clear: { log.events.append("clear") },
            dismiss: { log.events.append("dismiss") })))
    }

    @Test("a new goal needs an objective, then saves it with its budget")
    func setGoal() throws {
      let screen = open(GoalSheetState(mode: .managed(goal: nil)))
      defer { screen.close() }
      #expect(try screen.shows("Set a goal"))
      #expect(try screen.shows("Set Goal"))
      let withoutSave = screen.buttons.count
      try screen.type("Ship it", intoField: 0)
      try screen.type("1,000", intoField: 1)
      #expect(screen.buttons.count == withoutSave + 1)
      try screen.tapButton(fromEnd: 0)
      #expect(log.events == ["submit:Ship it:1000"])
    }

    @Test("a budget that isn't a number blocks the save; none means no limit")
    func budget() throws {
      let screen = open(GoalSheetState(mode: .managed(goal: nil)))
      defer { screen.close() }
      let withoutSave = screen.buttons.count
      try screen.type("Ship it", intoField: 0)
      try screen.type("lots", intoField: 1)
      #expect(screen.buttons.count == withoutSave, "still no Save")
      let plain = open(GoalSheetState(mode: .managed(goal: nil)))
      defer { plain.close() }
      try plain.type("Ship it", intoField: 0)
      try plain.tapButton(fromEnd: 0)
      #expect(log.events == ["submit:Ship it:none"])
    }

    @Test("Return saves and Esc cancels")
    func keyboard() throws {
      let screen = open(GoalSheetState(mode: .managed(goal: nil)))
      defer { screen.close() }
      try screen.type("Ship it", intoField: 0)
      #expect(try screen.pressShortcut(keyCode: 36, characters: "\r", modifiers: []))
      #expect(log.events == ["submit:Ship it:none"])
      #expect(try screen.pressShortcut(keyCode: 53, characters: "\u{1B}", modifiers: []))
      #expect(log.events.last == "dismiss")
    }

    @Test("a running goal shows its progress and offers Pause, Clear and Update")
    func runningGoal() throws {
      let goal = ComposerGoal(
        objective: "Ship it", status: "active", usage: "10 / 100 tokens", tokenBudget: 100,
        canPause: true)
      let screen = open(GoalSheetState(mode: .managed(goal: goal)))
      defer { screen.close() }
      #expect(try screen.shows("Goal"))
      #expect(try screen.shows("10 / 100 tokens"))
      #expect(try screen.shows("Update Goal"))
      #expect(try screen.shows("Clear Goal"))
      try screen.tapButton(fromEnd: 2)
      try screen.tapButton(fromEnd: 1)
      try screen.tapButton(fromEnd: 0)
      #expect(log.events == ["active:false", "dismiss", "submit:Ship it:100"])
    }

    @Test("a paused goal offers Resume; one that can do neither offers only Clear")
    func pausedGoal() throws {
      let paused = open(
        GoalSheetState(
          mode: .managed(goal: ComposerGoal(objective: "O", status: "paused", canResume: true))))
      defer { paused.close() }
      #expect(try paused.shows("Resume"))
      try paused.tapButton(fromEnd: 2)
      #expect(log.events == ["active:true"])
      let done = open(
        GoalSheetState(mode: .managed(goal: ComposerGoal(objective: "O", status: "done"))))
      defer { done.close() }
      #expect(try done.shows("Clear Goal"))
      #expect(try !done.shows("Pause"))
      #expect(try !done.shows("Resume"))
    }

    @Test("a /goal harness starts one by command, without a budget")
    func commandGoal() throws {
      let screen = open(GoalSheetState(mode: .command(backend: "Claude")))
      defer { screen.close() }
      #expect(try screen.shows("Start a Claude goal"))
      #expect(try screen.shows("Start Goal"))
      #expect(screen.fields.count == 1)
      try screen.type("Done", intoField: 0)
      try screen.tapButton(fromEnd: 0)
      #expect(log.events == ["submit:Done:none"])
    }

    @Test("while busy nothing saves, and a failure says why")
    func busyAndFailed() throws {
      let goal = ComposerGoal(objective: "O", status: "active", canPause: true)
      let screen = open(
        GoalSheetState(mode: .managed(goal: goal), isBusy: true, errorMessage: "No network."))
      defer { screen.close() }
      #expect(try screen.shows("No network."))
      #expect(screen.allViews.contains { $0 is NSProgressIndicator })
      try screen.tapButton(fromEnd: 0)
      #expect(log.events == ["dismiss"], "Cancel is all that's left")
    }

    @Test("a viewer who can only read the goal has no way to change it")
    func readOnly() throws {
      let goal = ComposerGoal(objective: "O", status: "active", canPause: true)
      let screen = open(GoalSheetState(mode: .managed(goal: goal), isReadOnly: true))
      defer { screen.close() }
      #expect(try screen.shows("Status"))
      #expect(try !screen.shows("Clear Goal"))
      #expect(try !screen.shows("Pause"))
    }
  }
#endif
