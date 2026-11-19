import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  @testable import OmnigentUITestSupport
#endif

/// The Tasks tab as the web's `TasksPanel` draws it.
@Suite("Inspector: the Tasks tab", .serialized)
@MainActor
struct InspectorTasksPanelTests {
  private static let started = Date(timeIntervalSince1970: 1_795_080_500)

  private static var plan: TaskListState {
    TaskListState(
      planName: "Ship the JSON flag", updatedAt: started, summary: "2 of 4 finished",
      counts: [
        TaskCountLine(state: .running, text: "1 running"),
        TaskCountLine(state: .failed, text: "1 failed"),
      ],
      canStop: true, fromPlan: true,
      rows: [
        TaskRowState(
          id: "build", number: 1, name: "Build", state: .done, stateLabel: "Done",
          detail: .text("Compiled"), endedAt: started, markerRowID: "row_build",
          history: [
            TaskHistoryLine(
              id: "s1", label: "Started", state: .running, text: nil, date: started,
              restarted: false),
            TaskHistoryLine(
              id: "s2", label: "Done", state: .done, text: "Compiled", date: started,
              restarted: false),
          ]),
        TaskRowState(
          id: "test", number: 2, name: "Run the tests", state: .running, stateLabel: "Running",
          detail: .text("Running the suite"), runningSince: started,
          action: TaskMenuItem(kind: .stop, title: "Stop")),
        TaskRowState(
          id: "docs", number: 3, name: "Update the docs", state: .failed, stateLabel: "Failed",
          detail: .text("Lint broke"), action: TaskMenuItem(kind: .retry, title: "Retry")),
        TaskRowState(
          id: "ship", number: 4, name: "Ship it", state: .waiting, stateLabel: "Not started",
          detail: .cantStart(failed: "Update the docs"),
          dependsOn: ["Run the tests", "Update the docs"]),
      ])
  }

  @Test("Times read as the web writes them")
  func times() {
    #expect(TaskTimes.duration(8) == "8s")
    #expect(TaskTimes.duration(106) == "1m 46s")
    #expect(TaskTimes.duration(120) == "2m")
    #expect(TaskTimes.duration(3_720) == "1h 2m")
    #expect(TaskTimes.duration(0.2) == "1s")
    let now = Date(timeIntervalSince1970: 1_795_080_500)
    #expect(TaskTimes.ago(now.addingTimeInterval(-20), now: now) == "just now")
    #expect(TaskTimes.ago(now.addingTimeInterval(-180), now: now) == "3m ago")
    #expect(TaskTimes.started(now, now: now) == "Started just now")
    #expect(TaskTimes.started(now.addingTimeInterval(-7_200), now: now) == "Started 2h ago")
    #expect(TaskTimes.names(["A"]) == "A")
    #expect(TaskTimes.names(["A", "B", "C"]) == "A, B and C")
    #expect(TaskTimes.names([]).isEmpty)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let today = TaskTimes.stamp(now, now: now, calendar: calendar)
    #expect(!today.contains(","), "today shows only the time: \(today)")
    let earlier = TaskTimes.stamp(
      now.addingTimeInterval(-86_400 * 400), now: now, calendar: calendar)
    #expect(earlier.contains(","), "another year shows the date: \(earlier)")
  }

  @Test("Colors and symbols follow each state")
  func styles() {
    #expect(TaskStyle.symbol(.stop) == "stop.fill")
    #expect(TaskStyle.symbol(.retry) == "arrow.counterclockwise")
    #expect(TaskStyle.symbol(.run) == "play.fill")
    #expect(TaskStyle.tint(.needsInput) == .system(.pink))
    #expect(TaskStyle.segment(.done) == .system(.green))
  }

  #if os(macOS)
    private final class Calls {
      var log: [String] = []
    }

    private func screen(_ state: TasksPanelState, calls: Calls, taskToShow: String? = nil)
      -> OffscreenWindow<TasksPanel>
    {
      SystemSideEffects.reset()
      let content = TasksPanelContent(
        state: state, taskToShow: taskToShow,
        perform: { calls.log.append("\($0.rawValue) \($1.id)") },
        stop: { calls.log.append("stop") }, continuePlan: { calls.log.append("continue") },
        showInChat: { calls.log.append("chat \($0)") }, retry: { calls.log.append("retry") },
        shown: { calls.log.append("shown") })
      return OffscreenWindow(TasksPanel(content: content), width: 420, height: 640)
    }

    @Test("A plan shows its name, summary, and each task's state and line")
    func planRows() throws {
      let calls = Calls()
      let shown = screen(.loaded(Self.plan), calls: calls)
      defer { shown.close() }
      #expect(try shown.shows("Ship the JSON flag"))
      #expect(try shown.shows("2 of 4 finished"))
      #expect(try shown.shows("1 running"))
      #expect(try shown.shows("Run the tests"))
      #expect(try shown.shows("Running the suite"))
      #expect(try shown.shows("Can't start"))
      #expect(try shown.shows("Update the docs failed"))
      #expect(try shown.shows("Updated"))
    }

    @Test("A stopping run shows Stopping in Stop's place, and nothing to press")
    func stopping() throws {
      var list = Self.plan
      list.canStop = false
      list.isStopping = true
      let shown = screen(.loaded(list), calls: Calls())
      defer { shown.close() }
      #expect(try shown.shows("Stopping\u{2026}"))
      let running = screen(.loaded(Self.plan), calls: Calls())
      defer { running.close() }
      #expect(try !running.shows("Stopping\u{2026}"))
      // The only button missing is Stop's.
      let buttons = { (screen: OffscreenWindow<TasksPanel>) in
        screen.allViews.filter { $0 is NSButton }.count
      }
      #expect(buttons(shown) == buttons(running) - 1)
    }

    @Test("Loading, a failed read, and no tasks each say so")
    func readStates() throws {
      let calls = Calls()
      let loading = screen(.loading, calls: calls)
      defer { loading.close() }
      #expect(loading.allViews.contains { $0 is NSProgressIndicator })
      let failed = screen(.failed("Couldn't load the session's tasks. Gone."), calls: calls)
      defer { failed.close() }
      #expect(try failed.shows("Couldn't load the session's tasks. Gone."))
      try failed.clickControl(at: 0)
      #expect(calls.log == ["retry"])
      let empty = screen(.empty, calls: calls)
      defer { empty.close() }
      #expect(try empty.shows("No tasks yet"))
      #expect(try empty.shows("Tasks show up here when the agent makes a to-do list."))
    }

    @Test("A task with a chat marker shows it in the chat, and a marker's task is shown once")
    func showInChat() async throws {
      let calls = Calls()
      let shown = screen(.loaded(Self.plan), calls: calls, taskToShow: "docs")
      defer { shown.close() }
      await shown.settleTasks()
      #expect(calls.log.contains("shown"), "the tab took the task to show")
      calls.log.removeAll()
      // Build's row is the one wide control: the segments share the width, the rest are icons.
      let row = try #require(shown.controlFrames.first { $0.width > 200 })
      try shown.click(CGPoint(x: row.midX, y: row.midY))
      #expect(calls.log == ["chat row_build"])
    }
  #endif
}
