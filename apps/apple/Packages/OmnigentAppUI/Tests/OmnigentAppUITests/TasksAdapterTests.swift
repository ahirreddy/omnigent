import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The Tasks tab from the core's records: the agent's own list from its `todos` section, the
/// chat's task markers, and the core's view mapped for the panel.
@Suite("Tasks tab mapping")
struct TasksAdapterTests {
  private func detail(_ id: String, _ title: String, _ text: String)
    -> OmnigentCoreFFI.DetailSection
  {
    OmnigentCoreFFI.DetailSection(id: id, title: title, text: text, isCode: false)
  }

  private func marker(_ rowID: String, task: String, marker: String) -> OmnigentCoreFFI.Row {
    let activity = OmnigentCoreFFI.Activity(
      kind: .taskMarker, title: "Completed", summary: task, status: "done",
      details: [detail("task", "Task", task), detail("marker", "Marker", marker)],
      isFailure: false, recovery: nil)
    return OmnigentCoreFFI.Row(
      id: rowID, role: .tool, text: "", isStreaming: false, activity: activity, attachments: [],
      callId: nil, responseId: nil, interrupted: false, author: nil, agent: nil,
      createdAt: nil, isEphemeral: false, isActivityOnly: false)
  }

  @Test("The agent's own tasks read from the todos section, keyed as the markers name them")
  func nativeTasks() {
    let section = OmnigentCoreFFI.EventSection(
      id: "todos", title: "Tasks", summary: "1 of 3 complete",
      details: [
        detail("task-1", "Completed: Read the code", "Read the code"),
        detail("toolu_2", "In progress: Fix the bug", "Fixing the bug"),
        detail("task-3", "Pending: Write: a test", "Write: a test"),
        detail("odd", "Unknown", "x"),
      ], sessionId: nil)
    let tasks = TasksAdapter.nativeTasks([section])
    #expect(tasks.map(\.id) == ["task-1", "toolu_2", "task-3"])
    #expect(tasks.map(\.status) == [.completed, .inProgress, .pending])
    #expect(tasks[1].activeForm == "Fixing the bug")
    #expect(tasks[0].activeForm == nil)
    #expect(tasks[2].content == "Write: a test", "only the status is split off")
    #expect(TasksAdapter.nativeTasks([]).isEmpty)
  }

  @Test("Task markers are found by the id the tab links to")
  func markerRows() {
    let rows = [
      marker("r1", task: "a", marker: "journal-e1"),
      marker("r2", task: "task-1", marker: "todo-task-1-done"),
    ]
    #expect(TasksAdapter.markerRows(rows) == ["journal-e1": "r1", "todo-task-1-done": "r2"])
  }

  @Test("The core's view maps to the panel, with marker rows and dates")
  func viewMapping() throws {
    let native = [
      NativeTask(id: "task-1", content: "Read", status: .completed, activeForm: nil),
      NativeTask(id: "task-2", content: "Fix", status: .inProgress, activeForm: "Fixing"),
    ]
    let view = tasksView(
      entries: [], nativeTasks: native, nativeMarkers: ["todo-task-1-done"],
      context: TasksContext(
        sessionWorking: false, awaitingUser: false, canSend: true, journalRead: true))
    let list = TasksAdapter.list(view, rows: ["todo-task-1-done": "row_1"])
    #expect(list.summary == "1 of 2 finished")
    #expect(list.paused == "Stopped")
    #expect(list.canContinue)
    #expect(list.rows.map(\.state) == [.done, .stopped])
    #expect(list.rows[0].markerRowID == "row_1")
    #expect(list.rows[1].action == TaskMenuItem(kind: .resume, title: "Continue"))
    #expect(list.rows[1].detail == .text("Fixing"))
    let state = TasksAdapter.state(view, tasks: nil, supported: false, rows: [:])
    guard case .loaded(let loaded) = state else {
      Issue.record("not loaded: \(state)")
      return
    }
    #expect(loaded.rows.count == 2)
    let none = tasksView(
      entries: [], nativeTasks: [], nativeMarkers: [],
      context: TasksContext(
        sessionWorking: false, awaitingUser: false, canSend: true, journalRead: true))
    #expect(TasksAdapter.state(none, tasks: nil, supported: true, rows: [:]) == .empty)
  }

  @MainActor
  @Test("The tab and the markers' links follow the agent's tasks, and a link opens the tab")
  func tabAndMarkerLinks() async throws {
    final class Opened { var count = 0 }
    let todos = OmnigentCoreFFI.EventSection(
      id: "todos", title: "Tasks", summary: "",
      details: [detail("task-1", "In progress: Fix it", "Fixing")], sessionId: nil)
    let conversation = try await ConversationFixtures.store(
      sections: [todos], rows: [marker("r1", task: "task-1", marker: "todo-task-1-started")])
    #expect(!TasksAdapter.keepsJournal(nil), "no store, no journal")
    #expect(TasksAdapter.showsTab(tasks: nil, conversation: conversation))
    let opened = Opened()
    let links = TasksAdapter.point(TaskMarkerLinks(), tasks: nil, conversation: conversation) {
      opened.count += 1
    }
    #expect(links.listed() == .shown(["task-1"]))
    links.open("task-1")
    #expect(opened.count == 1)
    // Opening a session with tasks shows the tab; one without them leaves the panel be.
    #expect(TasksAdapter.hasTasks(nil, conversation: conversation))

    let empty = try await ConversationFixtures.store()
    #expect(!TasksAdapter.hasTasks(nil, conversation: empty))
    #expect(!TasksAdapter.showsTab(tasks: nil, conversation: empty))
    #expect(TasksAdapter.listedTasks(tasks: nil, conversation: empty) == .hidden)
    let content = TasksAdapter.content(
      tasks: nil, conversation: empty, summary: nil,
      routes: TasksAdapter.Routes(showRow: { _ in }, report: { _ in }))
    #expect(content.state == .empty, "a tab that no longer shows draws nothing")
  }

  @MainActor
  @Test("A run works while its sandbox launches, until the launch is up or fails")
  func launchingCountsAsWorking() async throws {
    let cases: [(SandboxLaunchStage?, Bool)] = [
      (nil, false), (.provisioning, true), (.actionRequired, true), (.connecting, true),
      (.ready, false), (.failed, false),
    ]
    for (stage, working) in cases {
      let header = OmnigentCoreFFI.SessionHeader(
        id: "conv", title: "Run", status: .idle, readOnly: false, archived: false,
        permissionLevel: 4, failureMessage: nil, settings: nil,
        sandboxLaunch: stage.map {
          SandboxLaunch(stage: $0, provider: "example", details: nil, error: nil)
        })
      let conversation = try await ConversationFixtures.store(header: header)
      #expect(
        TasksAdapter.isWorking(conversation, summary: nil) == working,
        "\(String(describing: stage))")
    }
  }

  @Test("Menu actions map both ways")
  func actions() {
    for action in [TaskMenuAction.run, .resume, .proceed, .retry, .stop] {
      #expect(TasksAdapter.menuAction(TasksAdapter.coreAction(action)) == action)
    }
    #expect(TasksAdapter.historyState(.started) == .running)
    #expect(TasksAdapter.date(10) == Date(timeIntervalSince1970: 10))
  }
}
