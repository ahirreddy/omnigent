import OmnigentCoreFFI
import Testing

@testable import OmnigentStores

/// A session on a host the last host read did not list, such as a new session's sandbox that a
/// server replica never announced, has the hosts read again, once per host.
@MainActor
@Suite("Session list unlisted hosts")
struct SessionListUnlistedHostTests {
  private func summary(_ id: String, host: String?, owner: String? = nil) -> SessionSummary {
    let configuration = SessionConfiguration(
      agentId: nil, harness: nil, wrapper: nil, modelOverride: nil, baseModel: nil, effort: nil,
      modelReported: nil, effortReported: nil, models: [], hostId: host, hostOnline: nil,
      runnerOnline: nil, runnerBound: nil, hostResumable: nil, parentId: nil, routingMode: nil,
      approvalMode: nil)
    return SessionSummary(
      id: id, title: id, preview: "", status: .idle, pendingRequests: 0, isReadOnly: false,
      updatedAt: 0, workspace: "", agentName: "", isPinned: false, isArchived: false,
      permissionLevel: 4, failureMessage: nil, canRename: true, canPin: true, canArchive: true,
      configuration: configuration, owner: owner)
  }

  @Test("An owned session's unlisted host asks for one host read")
  func unlistedHostAsksOnce() {
    let list = SessionListStore()
    var reads = 0
    list.hostReads.reload = { reads += 1 }
    list.viewerID = "me"
    list.hostEnvironments = ["mac": .thisMachine]

    // Before the first read, that read is still coming.
    list.apply(.reset(sessions: [summary("early", host: "sbx-0")]))
    #expect(reads == 0)

    list.hostReads.hasRead = true
    // Listed hosts, no host, and someone else's host ask nothing.
    list.apply(
      .upsert(sessions: [
        summary("a", host: "mac"), summary("b", host: nil),
        summary("c", host: "theirs", owner: "other"),
      ]))
    #expect(reads == 0)

    list.apply(.upsert(sessions: [summary("d", host: "sbx-1"), summary("e", host: "sbx-1")]))
    #expect(reads == 1)
    // The same host again, as its row changes, asks no more; a new one does.
    list.apply(.upsert(sessions: [summary("d", host: "sbx-1")]))
    #expect(reads == 1)
    list.apply(.reset(sessions: [summary("d", host: "sbx-1"), summary("f", host: "sbx-2")]))
    #expect(reads == 2)

    // Another account starts over.
    list.clear()
    list.hostReads.hasRead = true
    list.viewerID = "me"
    list.apply(.upsert(sessions: [summary("d", host: "sbx-1")]))
    #expect(reads == 3)
  }
}
