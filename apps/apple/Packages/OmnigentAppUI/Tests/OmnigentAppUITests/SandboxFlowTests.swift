import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// A server offering a sandbox provider with profiles and GitHub, and a sandbox session to fork.
private func sandboxFlowServer(profilesFail: Bool = false) -> AppServer {
  let server = newSessionServer()
  server.route("/v1/info", .json(sandboxInfo))
  server.route(
    "/v1/sandbox-profiles",
    profilesFail
      ? .json(#"{"detail":"down"}"#, status: 500)
      : .json(
        #"{"profiles":[{"id":"p1","name":"GPU","description":"Fast","provider":"modal","revision":"r1"}],"managed_providers":["modal"],"next_cursor":null}"#
      ))
  server.route(
    "/v1/connections/github/repos",
    .json(
      #"{"connected":true,"truncated":false,"repos":[{"full_name":"o/a","default_branch":"main","private":true}]}"#
    ))
  server.route(
    "/v1/connections/github/repos/o/a/branches", .json(#"{"connected":true,"branches":["main"]}"#))
  let source =
    #"{"id":"conv_src","title":"Src","status":"idle","created_at":1,"updated_at":5,"permission_level":4,"agent_id":"ag_claude","labels":{"omnigent.sandbox.repo":"https://github.com/o/a#main https://github.com/o/b"},"sandbox_profile":{"id":"p1","name":"GPU","provider":"modal","revision":"r1"}}"#
  server.route("/v1/sessions/conv_src", .json(source))
  server.route(
    "/v1/sessions", method: "GET",
    .json(#"{"object":"list","data":[\#(source)],"has_more":false}"#))
  server.route(
    "/v1/sessions/conv_src/resources/repository-branches",
    .json(
      #"{"repositories":[{"url":"https://github.com/o/a","branch":"feat","pushed":true},{"url":"https://github.com/o/b","branch":"wip","pushed":false}]}"#
    ))
  server.route(
    "/v1/sessions/conv_src/fork", method: "POST",
    .json(#"{"id":"conv_f","status":"idle","created_at":5,"permission_level":4}"#, status: 201))
  return server
}

private let sandboxInfo =
  #"{"single_user":true,"accounts_enabled":false,"managed_sandboxes_enabled":true,"sandbox_providers":["modal"],"default_sandbox_provider":"modal","features":{"sandbox_profiles":true},"session_fork_workspaces":true,"enabled_connections":["github"]}"#

/// What a new sandbox's pickers read, and what they send, on the form and the fork sheet.
@MainActor
@Suite("Sandbox flows", .timeLimit(.minutes(1)))
struct SandboxFlowTests {
  private func stores(
    _ server: AppServer = sandboxFlowServer()
  ) async throws -> (SandboxStore, OmnigentCoreFFI.CreationCatalog) {
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    await creation.loadCatalog()
    return (try #require(connection.sandboxes()), try #require(creation.catalog.value))
  }

  @Test("Choosing a sandbox reads the caller's repositories and the provider's profiles")
  func readingWhatItOffers() async throws {
    let (sandboxes, catalog) = try await stores()
    var choices = SandboxChoices(provider: "modal")
    await choices.load(catalog, sandboxes: sandboxes)
    let repositories = choices.repositoriesState(catalog, sandboxes: sandboxes)
    #expect(repositories.githubRepos.map(\.fullName) == ["o/a"])
    #expect(repositories.githubRepos.first?.isPrivate == true)
    #expect(repositories.githubRepos.first?.defaultBranch == "main")
    #expect(repositories.githubError == nil)

    let profiles = try #require(choices.profilesState(catalog, sandboxes: sandboxes))
    #expect(profiles.profiles.map(\.name) == ["GPU"])
    #expect(!profiles.isLoading)
    #expect(choices.problem(catalog, sandboxes: sandboxes) != nil, "a profile must be chosen")

    choices.profile = profiles.profiles.first
    #expect(choices.problem(catalog, sandboxes: sandboxes) == nil)
    #expect(choices.chosenProfile(catalog)?.id == "p1")
    #expect(choices.chosenProfile(catalog)?.provider == "modal")
    #expect(choices.target(catalog).profile?.revision == "r1")
  }

  @Test("Profiles that can't load say so and block the start until Retry reads them")
  func aProfileFailure() async throws {
    let server = sandboxFlowServer(profilesFail: true)
    let (sandboxes, catalog) = try await stores(server)
    let choices = SandboxChoices(provider: "modal")
    await choices.load(catalog, sandboxes: sandboxes)
    #expect(
      choices.problem(catalog, sandboxes: sandboxes)
        == "Could not load sandbox profiles. Try again.")
    #expect(choices.profilesState(catalog, sandboxes: sandboxes)?.error?.isEmpty == false)

    let actions = try #require(
      SandboxChoices.profileActions("modal", sandboxes: sandboxes) { _ in })
    let searchProfiles = try #require(actions.search)
    let search = await searchProfiles("gp")
    #expect((try? search.get()) == nil, "a failed search reports its failure")

    server.route(
      "/v1/sandbox-profiles",
      .json(
        #"{"profiles":[{"id":"p1","name":"GPU","provider":"modal","revision":"r1"}],"managed_providers":["modal"]}"#
      ))
    let retry = try #require(actions.retry)
    retry()
    try await eventually("the retry") { sandboxes.profiles["modal"]?.value != nil }
    let found = try await searchProfiles("gp").get()
    #expect(found.map(\.id) == ["p1"])
  }

  @Test("A failed repository read shows as the picker's error; no sandboxes means no actions")
  func aRepositoryFailure() async throws {
    let server = sandboxFlowServer()
    server.route("/v1/connections/github/repos", .json(#"{"detail":"no"}"#, status: 500))
    let (sandboxes, catalog) = try await stores(server)
    let choices = SandboxChoices(provider: "modal")
    await choices.load(catalog, sandboxes: sandboxes)
    let state = choices.repositoriesState(catalog, sandboxes: sandboxes)
    #expect(state.githubError?.isEmpty == false)
    #expect(SandboxChoices.profileActions(nil, sandboxes: sandboxes) { _ in } == nil)
    #expect(SandboxChoices.profileActions("modal", sandboxes: nil) { _ in } == nil)
  }

  /// The fork flow for `conv_src`, with its store loaded.
  private func forkFlow(
    _ server: AppServer, source: OmnigentCoreFFI.SessionSummary? = nil
  ) async throws -> (ForkFlow, ForkStore) {
    let connection = try await signedInStore(server)
    let store = try #require(connection.makeForkStore())
    let flow = ForkFlow()
    let context = ForkContext(source: source ?? forkSource(), upToResponseID: nil, kind: .session)
    await flow.begin(context, makeStore: { store })
    return (flow, store)
  }

  private func forkSource() -> OmnigentCoreFFI.SessionSummary {
    ConversationFixtures.summary(
      "conv_src", workspace: "/work",
      configuration: ConversationFixtures.configuration())
  }

  @Test("A sandbox fork starts on the original's pushed branches and its profile")
  func aForkSeedsItsRepositories() async throws {
    let (flow, store) = try await forkFlow(sandboxFlowServer())
    await flow.sandboxSelected("modal")
    #expect(flow.isSandboxSeeded)
    #expect(flow.sandbox.repos.map(\.branch) == ["feat", ""], "the unpushed branch isn't offered")
    #expect(flow.sandbox.profile?.id == "p1")

    let state = try #require(flow.viewState)
    #expect(state.options.sandboxes.map(\.provider) == ["modal"])
    #expect(state.options.repositories.notes.count == 1)
    #expect(state.options.isCheckingBranches == false)
    var choices = ForkChoices(agentID: "ag_claude", directory: "", start: false, hostID: nil)
    choices.isSandbox = true
    choices.sandboxProvider = "modal"
    let request = flow.sandboxRequest(choices, store: store)
    #expect(request.provider == "modal")
    #expect(request.workspaces == ["https://github.com/o/a#feat", "https://github.com/o/b"])
  }

  @Test("Another provider forgets the profile; picking repositories and a profile edits the sheet")
  func theSheetsPickers() async throws {
    let (flow, _) = try await forkFlow(sandboxFlowServer())
    await flow.sandboxSelected("modal")
    let actions = flow.withSandboxActions(ForkActions(forkWith: { _ in }, cancel: {}))
    actions.repositories?.setRepos([SandboxRepoChoice(url: "https://github.com/o/c")])
    #expect(flow.sandbox.repos.map(\.url) == ["https://github.com/o/c"])
    actions.profiles?.select(SandboxProfileOption(id: "p2", name: "CPU", revision: "1"))
    #expect(flow.sandbox.profile?.id == "p2")
    actions.sandboxSelected?("other")
    try await eventually("the provider") { flow.sandbox.provider == "other" }
    #expect(flow.sandbox.profile == nil)
  }

  @Test("An original that can't be read leaves its repositories unchanged and says so")
  func anUnreadableOriginal() async throws {
    let server = sandboxFlowServer()
    let (flow, store) = try await forkFlow(server)
    server.route("/v1/sessions/conv_src", .json(#"{"detail":"gone"}"#, status: 500))
    await flow.sandboxSelected("modal")
    #expect(flow.isSandboxSeeded)
    #expect(flow.sandbox.repos.isEmpty)
    let state = try #require(flow.viewState)
    #expect(state.options.repositories.githubError?.contains("could not be read") == true)
    let request = flow.sandboxRequest(
      ForkChoices(agentID: "a", directory: "", start: false, hostID: nil), store: store)
    #expect(request.workspaces == nil, "the copy inherits them on the server")
  }

  @Test("The sheet's folder browser reads the chosen host, or asks for one")
  func theSheetsBrowser() async throws {
    let (flow, _) = try await forkFlow(sandboxFlowServer())
    let actions = flow.withSandboxActions(ForkActions(forkWith: { _ in }, cancel: {}))
    let browse = try #require(actions.browse)
    let listing = try await browse("mac", nil).get()
    #expect(listing.folders.map(\.name) == ["src"])
    #expect((try? await browse("gone", nil).get()) == nil)

    let (hostless, _) = try await forkFlow(
      newSessionServer(offline: ["mac", "box"]),
      source: ConversationFixtures.summary("conv_src"))
    let browseNoHost = try #require(
      hostless.withSandboxActions(ForkActions(forkWith: { _ in }, cancel: {})).browse)
    let noHost = await browseNoHost(nil, nil)
    if case .failure(let error) = noHost {
      #expect(error.message == "Choose a host first.")
    } else {
      Issue.record("a session with no host must ask for one")
    }
  }

  @Test("With no sheet open, choosing a provider does nothing")
  func noSheet() async {
    let flow = ForkFlow()
    await flow.sandboxSelected("modal")
    #expect(flow.sandbox.provider == nil)
    #expect(flow.withSandboxActions(ForkActions(forkWith: { _ in }, cancel: {})).browse == nil)
  }
}
