import OmnigentCoreFFI
import Testing

@testable import OmnigentStores

@MainActor
struct SubagentRollupTests {
  private func note(_ session: String, _ kind: NotificationKind, title: String? = nil)
    -> AttentionNotification
  {
    AttentionNotification(sessionId: session, kind: kind, title: title, body: "Agent finished.")
  }

  private let parent = ChildNotificationRollup.Parent(id: "parent", title: "Refactor auth")

  @Test func topLevelNotificationsPassThrough() {
    var rollup = ChildNotificationRollup()
    var pending: [AttentionNotification] = []
    rollup.add(note("parent", .completed, title: "Refactor auth"), to: &pending, parent: nil)
    #expect(pending == [note("parent", .completed, title: "Refactor auth")])
  }

  @Test func routineChildNotificationsFoldIntoTheParent() {
    var rollup = ChildNotificationRollup()
    var pending = [note("parent", .completed, title: "Refactor auth")]
    rollup.add(note("child-a", .completed, title: "Write tests"), to: &pending, parent: parent)
    #expect(pending.count == 2)
    #expect(pending[1].sessionId == "parent")
    #expect(pending[1].title == "Refactor auth")
    #expect(pending[1].body == "Subagent \u{201C}Write tests\u{201D} finished.")
    rollup.add(
      note("child-b", .completed), to: &pending, parent: parent, childTitle: "Review patch")
    // One rollup for the parent; the parent's own notification is untouched.
    #expect(pending.count == 2)
    #expect(pending[0].body == "Agent finished.")
    #expect(pending[1].body == "2 subagents finished.")
    rollup.add(
      note("child-b", .completed), to: &pending, parent: parent, childTitle: "Review patch")
    #expect(pending[1].body == "2 subagents finished.")
  }

  @Test func aBlockedChildStillNotifiesThroughItsParent() {
    var rollup = ChildNotificationRollup()
    var pending: [AttentionNotification] = []
    rollup.add(note("child-a", .completed, title: "Write tests"), to: &pending, parent: parent)
    rollup.add(note("child-b", .approval, title: "Check migrations"), to: &pending, parent: parent)
    #expect(pending.map(\.kind) == [.completed, .approval])
    #expect(pending.allSatisfy { $0.sessionId == "parent" })
    #expect(
      pending[1].body == "Subagent \u{201C}Check migrations\u{201D} is asking for your input.")
    rollup.reset()
    var next: [AttentionNotification] = []
    rollup.add(note("child-c", .failed, title: "Lint"), to: &next, parent: parent)
    #expect(next.map(\.body) == ["Subagent \u{201C}Lint\u{201D} failed."])
  }

  @Test func theListKnowsEachChildsParent() {
    let store = SessionListStore()
    var child = SessionSummary(
      id: "child", title: "Write tests", preview: "", status: .running, pendingRequests: 0,
      isReadOnly: false, updatedAt: 2, workspace: "", agentName: "", isPinned: false,
      isArchived: false, permissionLevel: 4, failureMessage: nil, canRename: true, canPin: true,
      canArchive: true)
    child.configuration = SessionConfiguration(
      agentId: nil, harness: nil, wrapper: nil, modelOverride: nil, baseModel: nil, effort: nil,
      modelReported: nil, effortReported: nil, models: [], hostId: nil, hostOnline: nil,
      runnerOnline: nil, runnerBound: nil, hostResumable: nil, parentId: "parent",
      routingMode: nil)
    var top = child
    top.id = "parent"
    top.configuration = nil
    store.apply(.reset(sessions: [child, top]))
    #expect(store.parent(of: "child") == "parent")
    #expect(store.parent(of: "parent") == nil)
    #expect(store.parent(of: "unknown") == nil)
  }
}
