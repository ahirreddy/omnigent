import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
@Suite("Agents tab and background tasks adapters")
struct AgentTreeAdapterTests {
  @Test("a core node maps to the panel's node with its status and role")
  func nodeMapping() {
    let node = AgentNode(
      sessionId: "conv_a", parentId: "conv_root", depth: 2, name: "Investigate auth",
      role: .explore, activity: .needsYou, statusLabel: "Needs you", statusDetail: nil,
      isSettled: false, preview: "Reading files", routedModel: "sonnet", childCount: 3)
    let mapped = AgentTreeAdapter.node(node)
    #expect(mapped.id == "conv_a" && mapped.parentID == "conv_root" && mapped.depth == 2)
    #expect(mapped.role == .explore && mapped.activity == .needsYou)
    #expect(mapped.preview == "Reading files" && mapped.routedModel == "sonnet")
    #expect(mapped.childCount == 3)
    for activity in [AgentActivity.launching, .working, .done, .failed, .disconnected, .idle] {
      #expect(AgentTreeAdapter.activity(activity) != .needsYou)
    }
  }

  @Test("named background tasks list in order and the note counts the unnamed ones")
  func backgroundTasks() {
    let section = OmnigentCoreFFI.EventSection(
      id: "background-tasks", title: "Background tasks", summary: "3 background tasks",
      details: [
        DetailSection(id: "sh_1", title: "Dev server", text: "npm run dev", isCode: true),
        DetailSection(id: "task-1", title: "tail -f log", text: "", isCode: true),
        DetailSection(
          id: "undetailed", title: "", text: "+1 more \u{2014} details unavailable",
          isCode: false),
      ], sessionId: nil)
    let tasks = SessionToolsAdapter.backgroundTasks([section])
    #expect(
      tasks.list == [
        ComposerBackgroundTask(id: "sh_1", title: "Dev server", command: "npm run dev"),
        ComposerBackgroundTask(id: "task-1", title: "tail -f log"),
      ])
    #expect(tasks.note == "+1 more \u{2014} details unavailable")
    #expect(SessionToolsAdapter.backgroundTasks([]).list.isEmpty)
  }
}
