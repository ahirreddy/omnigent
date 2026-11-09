import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import Testing

@testable import OmnigentAppUI

/// The folder a new session starts in: the host's most recent session's folder, else its home.
@MainActor
@Suite("New session folder default", .timeLimit(.minutes(1)))
struct NewSessionFolderDefaultTests {
  private func summary(
    _ id: String, host: String?, workspace: String, updatedAt: Int64 = 1
  ) -> OmnigentCoreFFI.SessionSummary {
    OmnigentCoreFFI.SessionSummary(
      id: id, title: id, preview: "", status: .idle, isReadOnly: false,
      updatedAt: updatedAt, workspace: workspace, agentName: "a",
      isPinned: false, isArchived: false, permissionLevel: 4, failureMessage: nil,
      canRename: true, canPin: true, canArchive: true,
      configuration: SessionConfiguration(
        agentId: "a", harness: "codex-native", wrapper: nil, modelOverride: nil,
        baseModel: nil, effort: nil, modelReported: nil, effortReported: nil, models: [],
        hostId: host, hostOnline: true, runnerOnline: true, runnerBound: true,
        hostResumable: nil, parentId: nil, routingMode: nil))
  }

  /// A signed-in store whose list holds a session in `/work/recent` on `mac`.
  private func connected(
    _ server: AppServer, status: String = "idle"
  ) async throws -> ConnectionStore {
    let row = sessionRow(
      "conv_a", host: "mac", workspace: "/work/recent", updatedAt: 5, status: status)
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(row)],"has_more":false}"#))
    let connection = try await signedInStore(server)
    try await eventually("the session list") { connection.sessionList.session("conv_a") != nil }
    #expect(connection.sessionList.session("conv_a")?.workspace == "/work/recent")
    return connection
  }

  @Test func theMostRecentSessionsFolderOnThisHostWins() {
    let sessions = [
      summary("old", host: "mac", workspace: "/old", updatedAt: 1),
      summary("new", host: "mac", workspace: "/new", updatedAt: 9),
      summary("other", host: "box", workspace: "/box", updatedAt: 99),
      summary("label", host: "mac", workspace: "not-a-path", updatedAt: 100),
      summary("empty", host: "mac", workspace: "", updatedAt: 101),
      summary("no-host", host: nil, workspace: "/nowhere", updatedAt: 102),
    ]
    #expect(NewSessionForm.recentFolder(hostID: "mac", sessions: sessions) == "/new")
    #expect(NewSessionForm.recentFolder(hostID: "box", sessions: sessions) == "/box")
    #expect(NewSessionForm.recentFolder(hostID: "gone", sessions: sessions) == nil)
    #expect(NewSessionForm.recentFolder(hostID: "mac", sessions: []) == nil)
  }

  @Test func equallyRecentSessionsPickTheSameFolderWhateverTheirOrder() {
    let first = summary("a", host: "mac", workspace: "/a", updatedAt: 5)
    let second = summary("b", host: "mac", workspace: "/b", updatedAt: 5)
    let forward = NewSessionForm.recentFolder(hostID: "mac", sessions: [first, second])
    let backward = NewSessionForm.recentFolder(hostID: "mac", sessions: [second, first])
    #expect(forward == backward)
  }

  @Test("A host with sessions starts in its recent folder and asks for no home listing")
  func recentFolderNeedsNoHomeListing() async throws {
    let server = newSessionServer()
    server.route("/v1/hosts/mac/filesystem", .json(#"{"detail":"no"}"#, status: 500))
    let connection = try await connected(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    await form.seedFolder(creation, list: connection.sessionList)
    #expect(form.folder == "/work/recent")
    #expect(form.selection.workspace == "/work/recent")
  }

  @Test("A filter or search hiding every session leaves the folder on the recent one")
  func aFilteredListDoesNotFlipTheFolderToHome() async throws {
    let server = newSessionServer()
    let connection = try await connected(server)
    connection.sessionList.filter = .needsResponse
    #expect(connection.sessionList.visible.isEmpty)
    let creation = try #require(connection.creation())
    let filtered = try isolatedForm()
    await filtered.load(creation)
    await filtered.seedFolder(creation, list: connection.sessionList)
    #expect(filtered.folder == "/work/recent")

    connection.sessionList.filter = .all
    connection.sessionList.searchText = "nothing matches this"
    #expect(connection.sessionList.visible.isEmpty)
    let searched = try isolatedForm()
    await searched.load(creation)
    await searched.seedFolder(creation, list: connection.sessionList)
    #expect(searched.folder == "/work/recent")
  }

  @Test("An archived session's folder isn't offered as recent")
  func archivedSessionsDoNotSeed() async throws {
    let server = newSessionServer()
    let row = sessionRow(
      "conv_old", host: "mac", workspace: "/archived", updatedAt: 9, archived: true)
    server.route(
      "/v1/sessions", method: "GET", .json(#"{"object":"list","data":[\#(row)],"has_more":false}"#))
    let connection = try await signedInStore(server)
    try await eventually("the session list") { connection.sessionList.session("conv_old") != nil }
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    await form.seedFolder(creation, list: connection.sessionList)
    #expect(form.folder == "/home/mac")
  }

  @Test("With no sessions on the host it starts in the host's home folder")
  func homeFolderWithoutSessions() async throws {
    let server = newSessionServer()
    let connection = try await signedInStore(server)
    try await eventually("the session list") { connection.sessionList.isLoaded }
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    await form.seedFolder(creation, list: connection.sessionList)
    #expect(form.folder == "/home/mac")
  }

  @Test("It waits for the session list instead of settling on home")
  func waitsForTheSessionList() async throws {
    let server = newSessionServer()
    let list = SessionListStore()
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    await form.seedFolder(creation, list: list)
    #expect(form.folder.isEmpty, "the sessions are not read yet")
    #expect(form.seededFolderHost == nil)
  }

  @Test("A session list that fails to load still lets home fill the folder")
  func aFailedListFallsBackToHome() async throws {
    let server = newSessionServer()
    server.route("/v1/sessions", method: "GET", .json(#"{"detail":"no"}"#, status: 500))
    let connection = try await signedInStore(server)
    try await eventually("the failure") { connection.sessionList.lastError != nil }
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    await form.seedFolder(creation, list: connection.sessionList)
    #expect(form.folder == "/home/mac")
  }

  @Test("A folder the user chose is never overwritten")
  func aChosenFolderStays() async throws {
    let server = newSessionServer()
    let connection = try await connected(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    form.selectFolder(creation, "/mine")
    await form.seedFolder(creation, list: connection.sessionList)
    #expect(form.folder == "/mine")
  }

  @Test("A host that can't list its home is tried again when it comes online")
  func anOfflineHostLeavesTheFolderEmpty() async throws {
    let server = newSessionServer(offline: ["mac", "box"])
    server.route("/v1/hosts/mac/filesystem", .json(#"{"detail":"offline"}"#, status: 503))
    let connection = try await signedInStore(server)
    try await eventually("the session list") { connection.sessionList.isLoaded }
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    let offlineTrigger = form.folderSeedTrigger(creation, list: connection.sessionList)
    await form.seedFolder(creation, list: connection.sessionList)
    #expect(form.folder.isEmpty)
    #expect(form.seededFolderHost == nil, "so a later try isn't skipped")

    server.route(
      "/v1/hosts",
      .json(
        #"{"hosts":[{"host_id":"mac","name":"mac","status":"online","configured_harnesses":{"claude-native":true}}]}"#
      ))
    server.route(
      "/v1/hosts/mac/filesystem",
      .json(
        #"{"data":[{"name":"src","path":"/home/mac/src","type":"directory"}],"has_more":false}"#))
    await creation.refreshCatalog()
    #expect(form.folderSeedTrigger(creation, list: connection.sessionList) != offlineTrigger)
    await form.seedFolder(creation, list: connection.sessionList)
    #expect(form.folder == "/home/mac")
  }

  @Test("A new sandbox has no folder to fill; coming back to the host fills it")
  func sandboxThenBackToHost() async throws {
    let server = newSessionServer()
    let connection = try await connected(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    form.isSandbox = true
    let sandboxTrigger = form.folderSeedTrigger(creation, list: connection.sessionList)
    await form.seedFolder(creation, list: connection.sessionList)
    #expect(form.folder.isEmpty)

    form.isSandbox = false
    #expect(form.folderSeedTrigger(creation, list: connection.sessionList) != sandboxTrigger)
    await form.seedFolder(creation, list: connection.sessionList)
    #expect(form.folder == "/work/recent")
  }

  @Test("Another host fills its own folder: a path from the last host doesn't follow")
  func anotherHostGetsItsOwnFolder() async throws {
    let server = newSessionServer()
    let connection = try await connected(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    await form.seedFolder(creation, list: connection.sessionList)
    #expect(form.folder == "/work/recent")

    form.chooseHost("box", creation)
    #expect(form.folder.isEmpty, "the path belongs to the other machine")
    #expect(form.selection.workspace.isEmpty)
    await form.seedFolder(creation, list: connection.sessionList)
    #expect(form.folder == "/home/box")
  }

  @Test("Picking the host already selected keeps the folder")
  func theSameHostKeepsTheFolder() async throws {
    let server = newSessionServer()
    let connection = try await connected(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    form.selectFolder(creation, "/mine")
    form.chooseHost(form.selection.hostId, creation)
    #expect(form.folder == "/mine")
    #expect(form.selection.workspace == "/mine")
  }

  @Test("A project's folder holds: the seed doesn't replace it")
  func aProjectFolderStays() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/projects/p1",
      .json(#"{"id":"p1","name":"Alpha","config":{"host_id":"mac","workspace":"/project"}}"#))
    let connection = try await connected(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    await form.applyProject(ProjectSummary(id: "p1", name: "Alpha", icon: nil), creation)
    #expect(form.folder == "/project")
    await form.seedFolder(creation, list: connection.sessionList)
    #expect(form.folder == "/project")
  }
}
