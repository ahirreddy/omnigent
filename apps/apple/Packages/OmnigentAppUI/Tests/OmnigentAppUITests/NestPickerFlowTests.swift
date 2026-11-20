import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The Nests picker's server search: pages of the viewer's own title matches.
@MainActor
@Suite("Nests picker search", .serialized, .timeLimit(.minutes(1)))
struct NestPickerFlowTests {
  /// Answers each read from a script and records what was asked.
  private final class Server {
    var asked: [String] = []
    var pages: [String: Result<SessionSearchPage, CoreError>] = [:]
  }

  private func nest(_ id: String, owner: String = "me") -> OmnigentCoreFFI.SessionSummary {
    var row = ConversationFixtures.summary(id, title: id.capitalized)
    row.owner = owner
    row.family = SessionFamily(
      id: id, representativeId: id, representativeTitle: id.capitalized, pinned: false,
      pinnedAt: nil)
    return row
  }

  private func flow(_ server: Server) -> NestPickerFlow {
    NestPickerFlow(
      session: OmnigentUIComponents.SessionSummary(id: "solo", title: "Solo"), debounce: .zero,
      search: { query, after throws(CoreError) in
        let key = "\(query)@\(after ?? "")"
        server.asked.append(key)
        guard let page = server.pages[key] else { throw .InvalidState(message: "no page") }
        return try page.get()
      },
      isOwned: { $0.owner == "me" })
  }

  @Test("Typing searches once it rests; more matches page in; others' sessions are left out")
  func pages() async throws {
    let server = Server()
    server.pages["lead@"] = .success(
      SessionSearchPage(sessions: [nest("alpha"), nest("theirs", owner: "them")], nextCursor: "c1"))
    server.pages["lead@c1"] = .success(SessionSearchPage(sessions: [nest("beta")], nextCursor: nil))
    let search = flow(server)
    search.query = " lead "
    try await eventually("the first page") { search.results.hasMore }
    #expect(search.results.query == "lead")
    #expect(search.results.found.map(\.id) == ["alpha"])
    search.more()
    try await eventually("the second page") { search.results.found.count == 2 }
    #expect(search.results.found.map(\.id) == ["alpha", "beta"])
    #expect(!search.results.hasMore && !search.results.isSearching)
    #expect(server.asked == ["lead@", "lead@c1"])
  }

  @Test("A failed page offers Retry, which reads it again; clearing the text asks nothing")
  func retries() async throws {
    let server = Server()
    let search = flow(server)
    search.query = "lead"
    try await eventually("the failure") { search.results.failed }
    server.pages["lead@"] = .success(SessionSearchPage(sessions: [nest("alpha")], nextCursor: nil))
    search.more()
    try await eventually("the retried page") { !search.results.found.isEmpty }
    #expect(!search.results.failed)
    search.query = ""
    try await eventually("the cleared search") { search.results.query.isEmpty }
    #expect(search.results.found.isEmpty)
    #expect(server.asked == ["lead@", "lead@"])
  }
}
