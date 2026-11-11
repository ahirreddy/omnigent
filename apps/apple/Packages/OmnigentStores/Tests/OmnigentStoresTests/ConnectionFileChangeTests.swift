import Observation
import OmnigentCoreFFI
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentStores

/// A file an agent changes is counted for the open sessions whose workspace can show it, and a
/// reader of one session's count is told of that session's changes alone.
@MainActor
@Suite("Connection file changes", .timeLimit(.minutes(1)))
struct ConnectionFileChangeTests {
  private func summary(_ id: String, workspace: String, host: String? = "mac") -> SessionSummary {
    let configuration = SessionConfiguration(
      agentId: nil, harness: nil, wrapper: nil, modelOverride: nil, baseModel: nil, effort: nil,
      modelReported: nil, effortReported: nil, models: [], hostId: host, hostOnline: nil,
      runnerOnline: nil, runnerBound: nil, hostResumable: nil, parentId: nil, routingMode: nil,
      approvalMode: nil)
    return SessionSummary(
      id: id, title: id, preview: "", status: .idle, pendingRequests: 0, isReadOnly: false,
      updatedAt: 0, workspace: workspace, agentName: "", isPinned: false, isArchived: false,
      permissionLevel: 4, failureMessage: nil, canRename: true, canPin: true, canArchive: true,
      configuration: configuration)
  }

  private func change(_ store: ConnectionStore, in sessionID: String) {
    store.apply(
      .changedFiles(sessionId: sessionID, environmentId: "default", update: .loaded(files: [])))
  }

  /// A store with a workspace open for each of `sessions`.
  private func store(_ sessions: [SessionSummary], open: [String]) throws -> ConnectionStore {
    let store = try disconnectedStore(RouteServer())
    store.sessionList.apply(.reset(sessions: sessions))
    for sessionID in open { #expect(store.workspace(sessionID) != nil) }
    return store
  }

  @Test("A change counts for the session, the open ones in its directory, and no other")
  func countsForSharedWorkspaces() throws {
    let store = try store(
      [
        summary("changed", workspace: "/work/repo"),
        summary("same", workspace: "/work/repo/"),
        summary("inside", workspace: "/work/repo/packages/app"),
        summary("around", workspace: "/work"),
        summary("sibling", workspace: "/work/repository"),
        summary("elsewhere", workspace: "/home/me"),
        summary("other-host", workspace: "/work/repo", host: "box"),
        summary("closed", workspace: "/work/repo"),
      ],
      open: ["changed", "same", "inside", "around", "sibling", "elsewhere", "other-host"])
    change(store, in: "changed")
    let counts = ["changed", "same", "inside", "around"].map(store.fileChanges(in:))
    #expect(counts == [1, 1, 1, 1], "the sessions that can show the file")
    let others = ["sibling", "elsewhere", "other-host", "closed"].map(store.fileChanges(in:))
    #expect(others == [0, 0, 0, 0], "a directory beside it, another host, a session not open")
    #expect(store.workspaceStores["changed"]?.changesRevision == 1)
    #expect(store.workspaceStores["same"]?.changesRevision == 0, "its own store was not told")
  }

  @Test("What the list does not know counts as shared, so no workspace keeps old files")
  func unknownCountsAsShared() throws {
    let store = try store(
      [
        summary("known", workspace: "/work/repo"),
        summary("no-path", workspace: ""),
        summary("no-host", workspace: "/work/repo", host: nil),
      ],
      open: ["known", "no-path", "no-host", "unlisted"])
    change(store, in: "known")
    let counts = ["known", "no-path", "no-host", "unlisted"].map(store.fileChanges(in:))
    #expect(counts == [1, 1, 1, 1])
    // A session the list never had: every open workspace may hold its files.
    change(store, in: "stranger")
    let after = ["known", "no-path", "no-host", "unlisted"].map(store.fileChanges(in:))
    #expect(after == [2, 2, 2, 2])
    #expect(store.fileChanges(in: "stranger") == 0, "it has no workspace open to reload")
  }

  @Test("A reader of one session's count is told of a change in its workspace, not another's")
  func readerIsToldOfItsOwn() throws {
    let store = try store(
      [summary("shown", workspace: "/work/a"), summary("other", workspace: "/work/b")],
      open: ["shown", "other"])
    let told = Mutex(false)
    withObservationTracking {
      _ = store.fileChanges(in: "shown")
    } onChange: {
      told.withLock { $0 = true }
    }
    change(store, in: "other")
    #expect(!told.withLock { $0 }, "another workspace's file")
    #expect(store.fileChanges(in: "other") == 1)
    change(store, in: "shown")
    #expect(told.withLock { $0 })
    #expect(store.fileChanges(in: "shown") == 1)
  }
}
