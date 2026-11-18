#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Task markers open the Tasks tab, as the web's `TaskActivityMessage` links them.
  @Suite("Task markers link to the Tasks tab", .serialized)
  @MainActor
  struct TranscriptTaskMarkerLinkTests {
    private typealias Fixture = TranscriptFixture

    init() {
      SystemSideEffects.reset()
    }

    private func marker(task: String, list: String = "The plan") -> Row {
      Fixture.activityRow(
        .taskMarker, id: "m1", title: "Completed", summary: "Run the tests", status: "done",
        details: [
          DetailSection(id: "task", title: "Task", text: task, isCode: true),
          DetailSection(id: "text", title: "Note", text: "All green"),
          DetailSection(id: "list", title: "List", text: list),
          DetailSection(id: "marker", title: "Marker", text: "journal-e1", isCode: true),
        ])
    }

    private func screen(_ row: Row, links: TaskMarkerLinks?) -> OffscreenWindow<AnyView> {
      transcriptScreen(AnyView(ActivityRowView(row: row).environment(\.taskMarkerLinks, links)))
    }

    @Test("A task the tab lists opens it at that task")
    func currentTaskOpens() throws {
      let log = HostLog()
      let links = TaskMarkerLinks(taskIDs: ["test"]) { log.add("tasks \($0 ?? "-")") }
      let shown = screen(marker(task: "test"), links: links)
      defer { shown.close() }
      #expect(try shown.shows("Completed"))
      #expect(try shown.shows("Run the tests"))
      // By identifier, as a UI test finds it.
      try shown.clickElement("task-marker-open-m1")
      #expect(log.entries == ["tasks test"])
    }

    @Test("A task its plan dropped stays plain, and says why on hover")
    func droppedTaskStaysPlain() throws {
      let links = TaskMarkerLinks(taskIDs: ["other"]) { _ in Issue.record("it linked") }
      let shown = screen(marker(task: "test"), links: links)
      defer { shown.close() }
      #expect(try shown.shows("Run the tests"))
      #expect(shown.controlFrames.isEmpty)
      let row = marker(task: "test", list: "The agent's tasks")
      let activity = try #require(row.activity)
      #expect(
        TranscriptMarker.droppedNote(activity) == "All green \u{00B7} No longer in the task list")
      #expect(TranscriptMarker.task(activity) == "test")
    }

    @Test("A plan line opens the Tasks tab; without links it is plain text")
    func planLineOpens() throws {
      let log = HostLog()
      let plan = Fixture.activityRow(
        .taskMarker, id: "p1", title: "Made a plan: Ship it \u{00B7} 2 tasks", status: "plan")
      let linked = screen(
        plan, links: TaskMarkerLinks(taskIDs: []) { log.add("tasks \($0 ?? "-")") })
      defer { linked.close() }
      try linked.clickElement("task-marker-open-p1")
      #expect(log.entries == ["tasks -"])
      let plain = screen(plan, links: nil)
      defer { plain.close() }
      #expect(plain.controlFrames.isEmpty)
      let activity = try #require(plan.activity)
      #expect(TranscriptMarker.isPlanLine(activity))
      #expect(TranscriptMarker.task(activity) == nil)
    }

    @Test("The CLI style offers Show in Tasks for what links")
    func cliAction() throws {
      let log = HostLog()
      let links = TaskMarkerLinks(taskIDs: ["test"]) { log.add("tasks \($0 ?? "-")") }
      let current = try #require(marker(task: "test").activity)
      let action = try #require(TranscriptMarker.tasksAction(current, rowID: "m1", links: links))
      #expect(action.title == "Show in Tasks")
      action.perform()
      #expect(log.entries == ["tasks test"])
      let dropped = try #require(marker(task: "gone").activity)
      #expect(TranscriptMarker.tasksAction(dropped, rowID: "m1", links: links) == nil)
      #expect(TranscriptMarker.tasksAction(current, rowID: "m1", links: nil) == nil)
    }
  }
#endif
