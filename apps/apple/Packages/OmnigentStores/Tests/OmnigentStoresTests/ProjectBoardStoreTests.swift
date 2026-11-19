import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

private let reply = HttpResponse.json(
  ###"{"data":[{"id":"i3","type":"message","role":"assistant","content":[{"type":"output_text","text":"## Done\nAll tests pass. The flake is gone. Shipping."}]}],"has_more":false}"###
)

/// A project board's stores: its folder kept open while it shows, its read failures, and each
/// card's reply preview.
@MainActor
@Suite("Project board stores", .timeLimit(.minutes(1)))
struct ProjectBoardStoreTests {
  @Test("A shown board keeps its folder open beside the sidebar's, until its last view leaves")
  func boardFoldersStayOpen() {
    let paging = SessionListPaging()
    paging.setOpenFolders(["p1"])
    paging.setBoardShown("p2", true)
    #expect(paging.openFolderIDs == ["p1", "p2"])
    // A second window on the same board.
    paging.setBoardShown("p2", true)
    paging.setBoardShown("p2", false)
    #expect(paging.openFolderIDs == ["p1", "p2"])
    paging.setBoardShown("p2", false)
    #expect(paging.openFolderIDs == ["p1"])
    paging.setOpenFolders([])
    #expect(paging.openFolderIDs.isEmpty)
  }

  @Test("A folder's failed read stays with it until it loads, and a clear drops it")
  func folderFailures() {
    let store = SessionListStore()
    store.paging.folderFailed("p1", .InvalidState(message: "boom"))
    #expect(store.paging.folderFailures["p1"] != nil)
    #expect(store.editError != nil, "the failure shows where list failures do")
    store.paging.foldersChanged([
      ProjectFolderPaging(folderId: "p1", isLoaded: false, hasMoreAfter: false, isLoading: true)
    ])
    #expect(store.paging.folderFailures["p1"] == nil)
    store.paging.folderFailed("p1", .InvalidState(message: "again"))
    store.clear()
    #expect(store.paging.folderFailures.isEmpty)
  }

  @Test("A card's preview is the last reply's opening, read once per finished turn")
  func previews() async throws {
    let server = RouteServer()
    let path = "/v1/sessions/conv_a/items"
    server.fail(path)
    let connection = try await connectedStore(server)
    let previews = ProjectBoardPreviews(core: connection.core)

    await previews.load("conv_a", updatedAt: 5, isWorking: false)
    #expect(previews.errors["conv_a"] != nil)
    #expect(previews.previews["conv_a"] == nil)

    server.route(path, reply)
    await previews.load("conv_a", updatedAt: 5, isWorking: false)
    #expect(previews.errors["conv_a"] == nil)
    #expect(previews.previews["conv_a"] == "All tests pass. The flake is gone.")

    let reads = server.requests(to: path).count
    await previews.load("conv_a", updatedAt: 5, isWorking: false)
    #expect(server.requests(to: path).count == reads, "the same turn reads once")
    await previews.load("conv_a", updatedAt: 9, isWorking: true)
    #expect(server.requests(to: path).count == reads, "a working session keeps its last reply")
    await previews.load("conv_a", updatedAt: 9, isWorking: false)
    #expect(server.requests(to: path).count == reads + 1)
  }
}
