import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The sidebar's row menu and project folders: what shows when the server agrees, and when not.
@MainActor
@Suite("Sidebar actions", .timeLimit(.minutes(1)))
struct SessionListWriteTests {
  private let snapshot = #"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#

  /// A server with one session the caller owns and two projects, one only a legacy label.
  private func serverWithProjects() -> RouteServer {
    let server = RouteServer()
    server.route(
      "/v1/sessions",
      .json(
        #"{"object":"list","data":[\#(snapshot)],"has_more":false}"#))
    server.route("/v1/sessions/conv_a", method: "GET", .json(snapshot))
    server.route(
      "/v1/sessions/projects",
      .json(#"[{"id":"p1","name":"Alpha"},{"id":null,"name":"Legacy"}]"#))
    return server
  }

  private func connectedList(_ server: RouteServer) async throws -> SessionListStore {
    let store = try await connectedStore(server)
    let list = store.sessionList
    try await eventually("the list") { list.isLoaded && !list.projects.isEmpty }
    return list
  }

  @Test("Row actions reach the server and report a refusal")
  func rowActions() async throws {
    let server = serverWithProjects()
    let list = try await connectedList(server)
    #expect(await !list.stop("conv_a"))
    #expect(list.editError != nil)
    #expect(await !list.delete("conv_a"))
    #expect(await !list.delete("conv_a", deleteBranch: true))
    #expect(list.editError != nil)

    server.route("/v1/sessions/conv_a/events", method: "POST", .json(#"{"queued":false}"#))
    #expect(await list.stop("conv_a"))
    #expect(list.editError == nil, "the next success clears the failure")

    server.route("/v1/sessions/conv_a", method: "DELETE", .json("", status: 204))
    #expect(await list.delete("conv_a", deleteBranch: true))
    let delete = try #require(server.requests(to: "/v1/sessions/conv_a", method: "DELETE").last)
    #expect(delete.url.contains("delete_branch=true"))
  }

  @Test("Moving into a label-only project promotes it first; a failed promotion moves nothing")
  func movesIntoLegacyProject() async throws {
    let server = serverWithProjects()
    let list = try await connectedList(server)
    let legacy = try #require(list.projects.first { $0.id == nil })
    server.fail("/v1/projects", method: "POST")
    #expect(await !list.move("conv_a", to: legacy))
    #expect(list.editError != nil)
    #expect(server.requests(to: "/v1/sessions/conv_a", method: "PATCH").isEmpty)

    server.route(
      "/v1/projects", method: "POST", .json(#"{"id":"p2","name":"Legacy"}"#, status: 201))
    server.route(
      "/v1/sessions/conv_a", method: "PATCH",
      .json(
        #"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"project_id":"p2"}"#))
    #expect(await list.move("conv_a", to: legacy))
    #expect(
      try server.body(
        of: #require(
          server.requests(to: "/v1/sessions/conv_a", method: "PATCH").last))["project_id"]
        as? String == "p2")
    #expect(list.session("conv_a")?.projectId == "p2")
  }

  @Test("A project made with a refused icon is still returned and still listed")
  func createsProject() async throws {
    let server = serverWithProjects()
    let list = try await connectedList(server)
    let reads = { server.requests(to: "/v1/sessions/projects").count }
    let before = reads()

    #expect(await list.createProject(named: "New") == nil)
    #expect(list.editError != nil)
    #expect(reads() == before, "nothing changed, so nothing to reread")

    server.route(
      "/v1/projects", method: "POST", .json(#"{"id":"p9","name":"New"}"#, status: 201))
    let plain = await list.createProject(named: "New")
    #expect(plain?.id == "p9")
    #expect(list.editError == nil)
    #expect(reads() > before)

    let partial = await list.createProject(named: "New", icon: "x")
    #expect(partial?.id == "p9")
    #expect(list.editError != nil, "the icon failed; the folder exists anyway")
  }

  @Test("Renaming reports a failure and rereads only after it worked")
  func renames() async throws {
    let server = serverWithProjects()
    let list = try await connectedList(server)
    let project = try #require(list.projects.first { $0.id == "p1" })
    let before = server.requests(to: "/v1/sessions/projects").count
    #expect(await list.renameProject(project, to: "Beta") == nil)
    #expect(server.requests(to: "/v1/sessions/projects").count == before)

    server.route("/v1/sessions", .json(#"{"object":"list","data":[],"has_more":false}"#))
    server.route("/v1/projects/p1", method: "PATCH", .json(#"{"id":"p1","name":"Beta"}"#))
    #expect(await list.renameProject(project, to: "Beta")?.name == "Beta")
    #expect(server.requests(to: "/v1/sessions/projects").count > before)
    #expect(list.editError == nil)
  }

  @Test("Editing a project rereads either way, so a half-saved edit shows as it is")
  func editsProject() async throws {
    let server = serverWithProjects()
    let list = try await connectedList(server)
    let project = try #require(list.projects.first { $0.id == "p1" })
    let before = server.requests(to: "/v1/sessions/projects").count
    #expect(await !list.editProject(project, name: "Beta", icon: nil))
    #expect(list.editError != nil)
    #expect(server.requests(to: "/v1/sessions/projects").count == before + 1)

    #expect(await list.editProject(project, name: project.name, icon: project.icon))
    #expect(list.editError == nil)
    #expect(server.requests(to: "/v1/projects/p1", method: "PATCH").count == 1, "nothing changed")
  }

  @Test("Deleting a project reports a refusal and always rereads")
  func deletesProject() async throws {
    let server = serverWithProjects()
    let list = try await connectedList(server)
    let project = try #require(list.projects.first { $0.id == "p1" })
    server.route(
      "/v1/sessions/projects", .json(#"[{"id":"p1","name":"Alpha"}]"#))
    #expect(await !list.deleteProject(project))
    #expect(list.editError != nil)
    #expect(list.projects.map(\.id) == ["p1"], "the reread shows what is really there")

    server.route("/v1/sessions", .json(#"{"object":"list","data":[],"has_more":false}"#))
    server.route("/v1/projects/p1", method: "DELETE", .json("", status: 204))
    server.route("/v1/sessions/projects", .json("[]"))
    #expect(await list.deleteProject(project))
    #expect(list.projects.isEmpty)
  }

  @Test("A dragged project order shows at once and rolls back when the server refuses")
  func orderRollsBack() async throws {
    let server = serverWithProjects()
    server.route(
      "/v1/sessions/projects",
      .json(#"[{"id":"p1","name":"Alpha"},{"id":"p2","name":"Beta"}]"#))
    let gate = server.hold("/v1/projects/order", method: "PUT")
    server.fail("/v1/projects/order", method: "PUT")
    let list = try await connectedList(server)
    try await eventually("both projects") { list.projects.count == 2 }
    let original = list.projects
    let dragged = Array(original.reversed())
    let saving = Task { await list.saveProjectOrder(dragged) }
    try await eventually("the write") { gate.arrivals == 1 }
    #expect(list.projects == dragged, "the drop shows before the server answers")
    gate.release()
    #expect(await !saving.value)
    #expect(list.projects == original)
    #expect(list.editError != nil)
  }

  @Test("A sort mode saves its order, and Alphabetical reports a refusal")
  func sortModes() async throws {
    let server = serverWithProjects()
    let list = try await connectedList(server)
    server.fail("/v1/projects/order", method: "PUT")
    #expect(await !list.setProjectSortMode(.alphabetical, projects: list.projects))
    #expect(list.editError != nil)
    #expect(await !list.setProjectSortMode(.manual, projects: list.projects))

    server.route(
      "/v1/projects/order", method: "PUT",
      .json(#"{"sort_mode":"manual","ordered_project_ids":["p1"]}"#))
    let named = list.projects.filter { $0.id != nil }
    #expect(await list.setProjectSortMode(.manual, projects: named))
  }

  @Test("A failed project or host read shows until a later read works")
  func readsRecover() async throws {
    let server = serverWithProjects()
    let list = try await connectedList(server)
    server.fail("/v1/sessions/projects")
    await list.loadProjects()
    #expect(list.projectsError != nil)
    #expect(!list.projects.isEmpty, "the last list stays on screen")
    server.route("/v1/sessions/projects", .json("[]"))
    await list.loadProjects()
    #expect(list.projectsError == nil)
    #expect(list.projects.isEmpty)

    #expect(await list.loadHosts(serverURL: "http://127.0.0.1:6767").isEmpty)
    #expect(list.hostsError != nil)
    server.route(
      "/v1/hosts", .json(#"{"hosts":[{"host_id":"h1","name":"Box","status":"online"}]}"#))
    #expect(await list.loadHosts(serverURL: "http://127.0.0.1:6767").count == 1)
    #expect(list.hostsError == nil)
  }

  @Test("The draft marker follows the composer, and repeats change nothing")
  func draftMarkers() async throws {
    let list = try await connectedList(serverWithProjects())
    list.setDraft("conv_a", true)
    list.setDraft("conv_a", true)
    #expect(list.draftSessionIDs == ["conv_a"])
    list.setDraft("conv_a", false)
    list.setDraft("conv_a", false)
    #expect(list.draftSessionIDs.isEmpty)
  }

  @Test("Search finds sessions past the loaded list and throws what the server refused")
  func searches() async throws {
    let server = serverWithProjects()
    let list = try await connectedList(server)
    #expect(try await list.search("  ", inMessages: false).isEmpty)
    #expect(try await list.search("conv", inMessages: false).map(\.id) == ["conv_a"])

    server.fail("/v1/sessions")
    await #expect(throws: CoreError.self) { try await list.search("conv", inMessages: false) }
  }

  @Test("Without a server every action says so instead of doing nothing")
  func withoutACore() async {
    let list = SessionListStore()
    #expect(await !list.setUnread("conv_a", true))
    #expect(list.editError?.message == "Connect to a server before editing sessions.")
    await list.loadProjects()
    #expect(await list.loadHosts(serverURL: "http://x").isEmpty)
    await #expect(throws: CoreError.self) { try await list.search("x", inMessages: true) }
  }
}

/// Load More, and each project folder's own pages.
@MainActor
@Suite("Sidebar paging", .timeLimit(.minutes(1)))
struct SessionListPagingCoreTests {
  private func row(_ id: String) -> String {
    #"{"id":"\#(id)","status":"idle","created_at":1,"project_id":"p1"}"#
  }

  private func page(_ ids: [String], hasMore: Bool) -> HttpResponse {
    let rows = ids.map(row).joined(separator: ",")
    let more = hasMore ? "true" : "false"
    return .json(
      #"{"object":"list","data":[\#(rows)],"has_more":\#(more),"last_id":"\#(ids.last ?? "")"}"#)
  }

  private let project = ProjectSummary(id: "p1", name: "Alpha", icon: nil)

  @Test("Load More adds the next page and stops at the last")
  func loadMore() async throws {
    let server = RouteServer()
    server.route("/v1/sessions", page(["a1"], hasMore: true))
    let store = try await connectedStore(server)
    let list = store.sessionList
    let paging = list.paging
    try await eventually("the first page") { list.isLoaded && paging.hasMore }

    server.route("/v1/sessions", page(["a2"], hasMore: false))
    paging.loadMore()
    try await eventually("the second page") { list.session("a2") != nil }
    try await eventually("paging to end") { !paging.hasMore && !paging.isLoading }
    #expect(list.session("a1") != nil, "a later page adds to the first")
    let reads = server.requests(to: "/v1/sessions").count
    paging.loadMore()
    #expect(server.requests(to: "/v1/sessions").count == reads)
  }

  @Test("A folder reads its pages in turn and then has no more")
  func folderPages() async throws {
    let server = RouteServer()
    server.route("/v1/sessions", page(["a1"], hasMore: true))
    let store = try await connectedStore(server)
    let paging = store.sessionList.paging
    try await eventually("the list") { store.sessionList.isLoaded }

    await paging.loadProject(project, id: "folder")
    #expect(paging.projects["folder"]?.isLoaded == true)
    #expect(paging.projects["folder"]?.nextCursor != nil)
    #expect(paging.projects["folder"]?.hasMore == true)

    server.route("/v1/sessions", page(["a2"], hasMore: false))
    await paging.loadProject(project, id: "folder")
    #expect(paging.projects["folder"]?.hasMore == false)
    try await eventually("the page's rows") { store.sessionList.session("a2") != nil }

    let reads = server.requests(to: "/v1/sessions").count
    await paging.loadProject(project, id: "folder")
    #expect(server.requests(to: "/v1/sessions").count == reads, "every member is loaded")
  }

  @Test("A folder read that fails says so and can be tried again")
  func folderFails() async throws {
    let server = RouteServer()
    let store = try await connectedStore(server)
    let list = store.sessionList
    try await eventually("the list") { list.isLoaded }
    server.fail("/v1/sessions")
    await list.paging.loadProject(project, id: "folder")
    #expect(list.editError != nil)
    #expect(list.paging.projects["folder"]?.isLoaded == false)
    #expect(list.paging.projects["folder"]?.isLoading == false)

    server.route("/v1/sessions", page(["a1"], hasMore: false))
    await list.paging.loadProject(project, id: "folder")
    #expect(list.paging.projects["folder"]?.isLoaded == true)
  }

  @Test("A list reload while a folder reads drops the stale pages, which start again")
  func reloadDuringFolderRead() async throws {
    let server = RouteServer()
    let store = try await connectedStore(server)
    let paging = store.sessionList.paging
    try await eventually("the list") { store.sessionList.isLoaded }
    let gate = server.hold("/v1/sessions")
    let reading = Task { await paging.loadProject(project, id: "folder") }
    try await eventually("the read") { gate.arrivals == 1 }
    #expect(paging.projects["folder"]?.isLoading == true)
    await paging.loadProject(project, id: "folder")
    #expect(gate.arrivals == 1, "one page at a time")

    paging.listReset()
    gate.release()
    await reading.value
    #expect(paging.projects["folder"] == nil)
  }
}
