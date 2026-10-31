import XCTest

@testable import NativeLabCore

final class MobileCoreTests: XCTestCase {
  func testQueriesSearchContextAndGroupPinsBeforeRecents() {
    let olderPin = SessionSummary(
      id: "pin", title: "Café design", preview: "Review", updatedAt: Date(timeIntervalSince1970: 1),
      workspace: "Omni / iOS", agentName: "Codex", isPinned: true
    )
    let recent = SessionSummary(
      id: "new", title: "Build", preview: "Fix the keyboard",
      updatedAt: Date(timeIntervalSince1970: 3)
    )
    let earlier = SessionSummary(
      id: "old", title: "Notes", preview: "", updatedAt: Date(timeIntervalSince1970: 2)
    )
    let sessions = [earlier, recent, olderPin]
    XCTAssertEqual(SessionQuery.matching(sessions).map(\.id), ["pin", "new", "old"])
    for query in [" café ", "iOS", "Codex", "review"] {
      XCTAssertEqual(SessionQuery.matching(sessions, text: query).map(\.id), ["pin"])
    }
    XCTAssertEqual(SessionQuery.matching(sessions, text: "keyboard").map(\.id), ["new"])
    XCTAssertTrue(SessionQuery.matching(sessions, text: "unmatched").isEmpty)
  }

  func testArchivedDecisionsStayInAttentionAndFiltersAreExclusive() {
    let archived = SessionSummary(
      id: "archive", title: "Waiting", preview: "", status: .needsResponse, isArchived: true
    )
    let running = SessionSummary(id: "running", title: "Busy", preview: "", status: .running)
    let sessions = [archived, running]
    XCTAssertEqual(SessionQuery.matching(sessions).map(\.id), ["running"])
    XCTAssertEqual(SessionQuery.matching(sessions, filter: .running).map(\.id), ["running"])
    XCTAssertEqual(SessionQuery.matching(sessions, filter: .needsResponse).map(\.id), ["archive"])
    XCTAssertEqual(SessionQuery.matching(sessions, filter: .archived).map(\.id), ["archive"])
  }

  func testEqualTimestampsHaveStableOrdering() {
    let stamp = Date(timeIntervalSince1970: 10)
    let sessions = ["z", "a", "b"].map {
      SessionSummary(id: $0, title: $0, preview: "", updatedAt: stamp)
    }
    XCTAssertEqual(SessionQuery.matching(sessions).map(\.id), ["a", "b", "z"])
  }

  func testRenamePinArchiveRestoreAndReadOnlyGuards() async throws {
    let client = DemoSessionClient()
    let created = try await client.createSession(title: "Original")
    try await client.editSession(created.id, change: .title("  Renamed  "))
    try await client.editSession(created.id, change: .pinned(true))
    try await client.editSession(created.id, change: .archived(true))
    let archived = try await client.conversation(id: created.id)
    XCTAssertEqual(archived.session.title, "Renamed")
    XCTAssertTrue(archived.session.isPinned)
    XCTAssertTrue(archived.session.isArchived)
    XCTAssertEqual(archived.revision, created.revision + 3)
    XCTAssertEqual(archived.session.updatedAt, created.session.updatedAt)
    do {
      try await client.send("No hidden sends", to: created.id)
      XCTFail("Archived session accepted a message")
    } catch { XCTAssertEqual(error as? SessionClientError, .archived) }
    try await client.editSession(created.id, change: .archived(false))
    let restored = try await client.conversation(id: created.id)
    XCTAssertFalse(restored.session.isArchived)
    for change in [SessionChange.title("New"), .pinned(true), .archived(true)] {
      do {
        try await client.editSession("demo-notes", change: change)
        XCTFail("Read-only edit succeeded")
      } catch { XCTAssertEqual(error as? SessionClientError, .readOnly) }
    }
  }

  func testInvalidRenameDoesNotMutateSession() async throws {
    let client = DemoSessionClient()
    let before = try await client.conversation(id: "demo-design")
    for title in [" \n ", String(repeating: "x", count: 121)] {
      do {
        try await client.editSession("demo-design", change: .title(title))
        XCTFail("Invalid title accepted")
      } catch { XCTAssertEqual(error as? SessionClientError, .invalidTitle) }
    }
    let after = try await client.conversation(id: "demo-design")
    XCTAssertEqual(before, after)
  }

  func testPersistenceRoundTripsOrganizationAndExactDrafts() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LocalWorkspaceStore(url: directory.appendingPathComponent("workspace.json"))
    XCTAssertNil(try store.load())
    let client = DemoSessionClient()
    try await client.editSession("demo-design", change: .title("Mobile review"))
    try await client.editSession("demo-design", change: .archived(true))
    let snapshot = try await client.conversation(id: "demo-design")
    let workspace = LocalWorkspace(
      snapshots: [snapshot],
      drafts: ["demo-design": "  First line\n\n日本語 👋\n", "another": "Separate"]
    )
    try store.save(workspace)
    XCTAssertEqual(try store.load(), workspace)
    let restarted = DemoSessionClient(initialSnapshots: try XCTUnwrap(store.load()).snapshots)
    let restored = try await restarted.conversation(id: "demo-design")
    XCTAssertEqual(restored, snapshot)
  }

  func testRecoveryPreservesPartialTextAndEndsStreaming() {
    let running = ConversationSnapshot(
      revision: 8,
      session: SessionSummary(id: "running", title: "Demo", preview: "Partial", status: .running),
      messages: [
        ConversationMessage(id: "reply", role: .assistant, text: "Partial", isStreaming: true)
      ]
    )
    let recovered = LocalWorkspace(snapshots: [running], drafts: ["running": "Next question"])
      .recoveringInterruptedReplies()
    XCTAssertEqual(recovered.snapshots[0].revision, 9)
    XCTAssertEqual(recovered.snapshots[0].session.status, .idle)
    XCTAssertEqual(
      recovered.snapshots[0].messages[0].text,
      "Partial\n\nSample reply interrupted when the app closed.")
    XCTAssertFalse(recovered.snapshots[0].messages[0].isStreaming)
    XCTAssertEqual(recovered.drafts["running"], "Next question")
    XCTAssertEqual(recovered.recoveringInterruptedReplies(), recovered)
  }

  func testRestartDoesNotReuseMessageOrSessionIDs() async throws {
    let first = DemoSessionClient(responseDelayNanoseconds: 60_000_000_000)
    let session = try await first.createSession(title: "Before relaunch")
    try await first.send("One", to: session.id)
    try await first.interrupt(sessionID: session.id)
    let before = try await first.conversation(id: session.id)
    let second = DemoSessionClient(
      responseDelayNanoseconds: 60_000_000_000, initialSnapshots: [before]
    )
    try await second.send("Two", to: session.id)
    try await second.interrupt(sessionID: session.id)
    let after = try await second.conversation(id: session.id)
    XCTAssertEqual(after.messages.count, 4)
    XCTAssertEqual(Set(after.messages.map(\.id)).count, 4)
    let another = try await second.createSession(title: "After relaunch")
    XCTAssertNotEqual(another.id, session.id)
  }

  func testCorruptOrFutureStoreThrowsAndLeavesFileUntouched() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = LocalWorkspaceStore(url: directory.appendingPathComponent("workspace.json"))
    let corrupt = Data("not-json".utf8)
    try corrupt.write(to: store.url)
    XCTAssertThrowsError(try store.load())
    XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
    var future = LocalWorkspace(snapshots: [])
    future.version = 999
    try store.save(future)
    XCTAssertThrowsError(try store.load())
  }

  func testDuplicateSessionIDsAreRejectedByStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LocalWorkspaceStore(url: directory.appendingPathComponent("workspace.json"))
    let snapshot = DemoFixtures.snapshots[0]
    try store.save(LocalWorkspace(snapshots: [snapshot, snapshot]))
    XCTAssertThrowsError(try store.load())
  }
}
