import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The Tasks tab's journal: read when the server keeps one, kept current by pushed entries.
@MainActor
@Suite("Session tasks", .timeLimit(.minutes(1)))
struct SessionTasksStoreTests {
  private let path = "/v1/sessions/conv_a/journal"

  private func entry(_ id: String, _ position: Int, kind: String, step: String?, content: String)
    -> String
  {
    let step = step.map { "\"\($0)\"" } ?? "null"
    return
      #"{"id":"\#(id)","position":\#(position),"created_at":\#(1_795_080_000 + position),"scheduled_task_run_id":null,"step":\#(step),"author":{"type":"agent"},"kind":"\#(kind)","content":\#(content),"workflow_id":null}"#
  }

  private func page(_ entries: [String], last: String?, more: Bool = false) -> HttpResponse {
    let last = last.map { "\"\($0)\"" } ?? "null"
    return .json(
      #"{"object":"list","data":[\#(entries.joined(separator: ","))],"first_id":null,"last_id":\#(last),"has_more":\#(more)}"#
    )
  }

  private var plan: String {
    entry(
      "p", 0, kind: "plan", step: nil,
      content: #"{"version":1,"name":"Ship","steps":[{"id":"a","name":"A","depends_on":[]}]}"#)
  }

  @Test("Without journals nothing is read; with them the journal is read once")
  func loadsWhenSupported() async throws {
    let server = RouteServer()
    server.route(path, page([plan], last: "p"))
    let connection = try await connectedStore(server)
    let tasks = try #require(connection.tasks("conv_a"))
    #expect(connection.tasks("conv_a") === tasks, "one store per session")
    await tasks.load(supported: false)
    #expect(tasks.journal == .unsupported)
    #expect(server.requests(to: path).isEmpty)
    await tasks.load(supported: true)
    #expect(tasks.entries.map(\.id) == ["p"])
    #expect(tasks.entries.first?.steps.map(\.id) == ["a"])
    let reads = server.requests(to: path).count
    await tasks.load(supported: true)
    #expect(server.requests(to: path).count == reads, "a read journal is not read again")
  }

  @Test("A pushed entry joins the journal; one the core could not read has the missed read")
  func pushedEntries() async throws {
    let server = RouteServer()
    server.route(path, page([plan], last: "p"))
    let connection = try await connectedStore(server)
    let tasks = try #require(connection.tasks("conv_a"))
    await tasks.load(supported: true)
    let pushed = JournalEntry(
      id: "s", position: 1, createdAt: 1_795_080_001, scheduledTaskRunId: nil, step: "a",
      kind: "status", workflowId: nil, status: .started, text: nil, name: nil, steps: [],
      version: nil, graphRevision: nil)
    await tasks.entryAppended(pushed)
    #expect(tasks.entries.map(\.id) == ["p", "s"])
    await tasks.entryAppended(pushed)
    #expect(tasks.entries.map(\.id) == ["p", "s"], "an entry is added once")

    let done = entry("d", 2, kind: "status", step: "a", content: #"{"status":"done"}"#)
    server.route(path, page([done], last: "d"))
    await tasks.entryAppended(nil)
    #expect(tasks.entries.map(\.id) == ["p", "s", "d"])
    let catchUp = try #require(server.requests(to: path).last)
    #expect(catchUp.url.contains("after=s"))
    #expect(catchUp.url.contains("order=asc"))
  }

  @Test("A failed read says why and is read again on Retry")
  func failureAndRetry() async throws {
    let server = RouteServer()
    server.fail(path, status: 500, detail: "journal broke")
    let connection = try await connectedStore(server)
    let tasks = try #require(connection.tasks("conv_a"))
    await tasks.load(supported: true)
    guard case .failed = tasks.journal else {
      Issue.record("not failed: \(tasks.journal)")
      return
    }
    #expect(tasks.entries.isEmpty)
    server.route(path, page([plan], last: "p"))
    await tasks.retry()
    #expect(tasks.entries.map(\.id) == ["p"])
    tasks.taskToShow = "a"
    connection.closeConversation("conv_a")
    #expect(connection.tasksStores["conv_a"] == nil, "closing the session drops its journal")
  }
}
