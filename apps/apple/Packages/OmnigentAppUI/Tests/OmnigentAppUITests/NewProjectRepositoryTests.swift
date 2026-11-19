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
      "/v1/hosts/mac/directories", method: "POST",
      .json(#"{"object":"directory","path":"/Users/me/Garden"}"#))
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
    // The repository comes from the web's picker: one, from GitHub or a URL.
    let picker = try #require(view.repositoryProjectActions().repositoryPicker)
    let state = picker([SandboxRepoChoice(url: "https://github.com/org/app", branch: "main")])
    #expect(state.maxRepos == 1)
    #expect(state.repos.map(\.branch) == ["main"])

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

  @Test("A Folder project keeps the host the user picked and its working directory")
  func folderProjects() async throws {
    let (view, server) = try await opened(features: #""project_repository_creation":true"#)
    let actions = view.repositoryProjectActions()
    var draft = ProjectRepositoryDraft()
    draft.targetID = "mac"
    // A host nobody picked stays each session's choice, as on the web.
    #expect(await actions.createFolderProject?("Garden", nil, draft) == nil)
    draft.targetChosen = true
    #expect(await actions.createFolderProject?("Garden", "🌱", draft) == nil)
    let made = try #require(await actions.createFolder?("mac", "Garden"))
    draft.workspace = try made.get()
    #expect(draft.workspace == "/Users/me/Garden")
    #expect(await actions.createFolderProject?("Garden", nil, draft) == nil)
    let folder = try #require(try server.posted("/v1/hosts/mac/directories").last)
    #expect(folder["path"] as? String == "~/Garden")
    let configs = try server.posted("/v1/projects").map { $0["config"] as? [String: String] }
    #expect(
      configs == [
        nil, ["icon": "🌱", "host_id": "mac"],
        ["host_id": "mac", "workspace": "/Users/me/Garden"],
      ])
  }

  @Test("Clone into follows the folder Browse picks; a Folder project names its host when asked")
  func draftRules() {
    #expect(ProjectRepositoryDraft.join("~", "app") == "~/app")
    #expect(ProjectRepositoryDraft.join("/srv/code/", "app") == "/srv/code/app")
    var draft = ProjectRepositoryDraft()
    #expect(!draft.namesHost)
    draft.createsFolder = true
    #expect(draft.namesHost)
  }

  @Test("A sandbox choice names its provider; a host choice names the host")
  func targets() {
    #expect(ConnectedServerView.runTarget("mac") == .host(hostId: "mac"))
    #expect(ConnectedServerView.runTarget("__sandbox__:modal") == .sandbox(provider: "modal"))
    #expect(ConnectedServerView.runTarget("__sandbox__:") == .sandbox(provider: nil))
  }
}
