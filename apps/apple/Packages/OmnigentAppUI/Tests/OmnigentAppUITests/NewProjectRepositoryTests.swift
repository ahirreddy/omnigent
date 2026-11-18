import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// New project from a repository (`project_repository_creation`): where it can run, and that
/// a host clones the repository before the project names the checkout.
@MainActor
@Suite("New project from a repository", .serialized, .timeLimit(.minutes(1)))
struct NewProjectRepositoryTests {
  private func opened(features: String, sandboxes: Bool = false) async throws -> (
    ConnectedServerView, AppServer
  ) {
    let server = threeSessionServer()
    let managed =
      sandboxes ? #","managed_sandboxes_enabled":true,"sandbox_providers":["modal"]"# : ""
    server.route(
      "/v1/info",
      .json(#"{"single_user":true,"accounts_enabled":false,"features":{\#(features)}\#(managed)}"#))
    server.route(
      "/v1/hosts",
      .json(
        #"{"hosts":[{"host_id":"mac","name":"Mac","status":"online"},{"host_id":"off","name":"Old","status":"offline"}]}"#
      ))
    server.route(
      "/v1/hosts/mac/repositories/clone", method: "POST",
      .json(#"{"object":"repository","path":"/Users/me/app"}"#))
    server.route(
      "/v1/projects", method: "POST", .json(#"{"id":"p9","object":"project","name":"Garden"}"#))
    let session = try await signedInSession(server)
    _ = await session.connection.pages?.loadOffered()
    await session.connection.creation()?.loadCatalog()
    return (connectedView(session, WindowSelection()), server)
  }

  @Test("It runs on online hosts, then the sandboxes; without the feature on none")
  func choices() async throws {
    let (view, _) = try await opened(
      features: #""project_repository_creation":true"#, sandboxes: true)
    #expect(view.newProjectRunChoices.map(\.id) == ["mac", "__sandbox__:modal"])
    #expect(view.newProjectRunChoices.last?.isSandbox == true)
    #expect(view.repositoryProjectActions().create != nil)

    let (plain, _) = try await opened(features: "")
    #expect(plain.newProjectRunChoices.isEmpty)
    #expect(plain.repositoryProjectActions().create == nil)
  }

  @Test("A host clones the repository, and the project names the checkout")
  func clonesThenCreates() async throws {
    let (view, server) = try await opened(features: #""project_repository_creation":true"#)
    let actions = view.repositoryProjectActions()
    #expect(actions.cloneDestination?("https://github.com/org/app.git") == "~/app")
    #expect(actions.problem?("", "main") == "Add the repository this branch belongs to.")
    var draft = ProjectRepositoryDraft()
    draft.targetID = "mac"
    draft.fromRepository = true
    draft.url = "https://github.com/org/app"
    draft.destination = "~/app"
    let failure = await actions.create?("Garden", nil, draft)
    #expect(failure == nil)
    let clone = try #require(try server.posted("/v1/hosts/mac/repositories/clone").last)
    #expect(clone["path"] as? String == "~/app")
    let project = try #require(try server.posted("/v1/projects").last)
    let config = try #require(project["config"] as? [String: Any])
    #expect(config["workspace"] as? String == "/Users/me/app")
    #expect(config["host_id"] as? String == "mac")
  }

  @Test("A sandbox choice names its provider; a host choice names the host")
  func targets() {
    #expect(ConnectedServerView.runTarget("mac") == .host(hostId: "mac"))
    #expect(ConnectedServerView.runTarget("__sandbox__:modal") == .sandbox(provider: "modal"))
    #expect(ConnectedServerView.runTarget("__sandbox__:") == .sandbox(provider: nil))
  }
}
