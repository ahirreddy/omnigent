import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The new-session composer's `/` skills and `@` files, before a session exists.
@MainActor
@Suite("New session completions", .timeLimit(.minutes(1)))
struct LaunchCompletionsStoreTests {
  private let target = LaunchCompletionsStore.Target(
    hostID: "h1", harness: "claude-native", agentID: "a1", folder: "/work/repo")

  private func completions(_ server: RouteServer) async throws -> LaunchCompletionsStore {
    try #require(try await connectedStore(server).launchCompletions())
  }

  private func routeSkills(_ server: RouteServer, warnings: String = "[]") {
    server.route(
      "/v1/skills",
      .json(#"{"skills":[{"name":"triage","description":"T"}],"warnings":\#(warnings)}"#))
  }

  private func routeRepo(_ server: RouteServer) {
    server.route(
      "/v1/hosts/h1/filesystem/work/repo",
      .json(
        #"{"data":[{"name":"README.md","path":"/work/repo/README.md","type":"file"},{"name":"src","path":"/work/repo/src","type":"directory"}],"has_more":false}"#
      ))
  }

  @Test("Skills read once per target and say why when they can't")
  func skills() async throws {
    let server = RouteServer()
    routeSkills(server, warnings: #"["bad.md"]"#)
    let store = try await completions(server)
    await store.loadSkills(target, unavailable: nil)
    #expect(store.skills.map(\.name) == ["triage"])
    #expect(store.skillsNote == "Some skills could not be read: bad.md")
    await store.loadSkills(target, unavailable: nil)
    #expect(server.requests(to: "/v1/skills").count == 1)

    await store.loadSkills(nil, unavailable: "Choose a folder first.")
    #expect(store.skills.isEmpty)
    #expect(store.skillsNote == "Choose a folder first.")

    server.fail("/v1/skills")
    await store.loadSkills(target, unavailable: nil)
    #expect(store.skillsNote?.hasPrefix("Skills are unavailable") == true)
    routeSkills(server)
    await store.loadSkills(target, unavailable: nil)
    #expect(store.skillsNote == nil, "a failed read can be tried again")
  }

  @Test("A slow read for a folder the user left doesn't replace the current one")
  func staleSkills() async throws {
    let server = RouteServer()
    routeSkills(server)
    let gate = server.hold("/v1/skills")
    let store = try await completions(server)
    let reading = Task { await store.loadSkills(target, unavailable: nil) }
    try await eventually("the read") { gate.arrivals == 1 }
    await store.loadSkills(nil, unavailable: "Pick a host.")
    gate.release()
    await reading.value
    #expect(store.skills.isEmpty)
    #expect(store.skillsNote == "Pick a host.")
  }

  @Test("A stale failure doesn't replace the current state either")
  func staleSkillFailure() async throws {
    let server = RouteServer()
    server.fail("/v1/skills")
    let gate = server.hold("/v1/skills")
    let store = try await completions(server)
    let reading = Task { await store.loadSkills(target, unavailable: nil) }
    try await eventually("the read") { gate.arrivals == 1 }
    await store.loadSkills(nil, unavailable: "Pick a host.")
    gate.release()
    await reading.value
    #expect(store.skillsNote == "Pick a host.")
  }

  @Test("A newer @ replaces the listing still waiting, so the old query never reads")
  func supersededMention() async throws {
    let server = RouteServer()
    routeRepo(server)
    let store = try await completions(server)
    store.draftChanged("see @oldquery", target: target)
    store.draftChanged("see @", target: target)
    try await eventually("the listing") { !store.mentionCandidates.isEmpty }
    #expect(!server.requests().contains { $0.url.contains("oldquery") })
  }

  @Test("Typing an @ lists the folder; removing it clears the list")
  func mentions() async throws {
    let server = RouteServer()
    routeRepo(server)
    let store = try await completions(server)
    store.draftChanged("see @", target: target)
    try await eventually("the listing") { !store.mentionCandidates.isEmpty }
    #expect(store.mentionCandidates.contains("README.md"))
    #expect(store.mentionCandidates.contains("src/"))
    #expect(store.mentionProblem == nil)

    store.draftChanged("see ", target: target)
    #expect(store.mentionCandidates.isEmpty)
    store.draftChanged("see @", target: nil)
    #expect(store.mentionCandidates.isEmpty, "no target turns mentions off")
  }

  @Test("A listing that fails says why, and clearing the @ clears the problem")
  func mentionFailure() async throws {
    let server = RouteServer()
    let store = try await completions(server)
    store.draftChanged("@zzz", target: target)
    try await eventually("the problem") { store.mentionProblem != nil }
    #expect(store.mentionProblem?.hasPrefix("Could not list the folder") == true)
    store.draftChanged("", target: target)
    #expect(store.mentionProblem == nil)
  }

  @Test("A query inside a folder lists that folder")
  func nestedQuery() async throws {
    let server = RouteServer()
    let folder = "/v1/hosts/h1/filesystem/work/repo/src"
    server.route(
      folder,
      .json(
        #"{"data":[{"name":"a.swift","path":"/work/repo/src/a.swift","type":"file"}],"has_more":false}"#
      ))
    let store = try await completions(server)
    var trailing = target
    trailing.folder = "/work/repo/"
    store.draftChanged("@src/a", target: trailing)
    try await eventually("the listing") { !store.mentionCandidates.isEmpty }
    #expect(store.mentionCandidates == ["src/a.swift"])
  }

  @Test("A superseded listing is dropped")
  func supersededListing() async throws {
    let server = RouteServer()
    routeRepo(server)
    let gate = server.hold("/v1/hosts/h1/filesystem/work/repo")
    let store = try await completions(server)
    store.draftChanged("@", target: target)
    try await eventually("the read") { gate.arrivals == 1 }
    store.draftChanged("no mention", target: target)
    gate.release()
    await Task.yield()
    #expect(store.mentionCandidates.isEmpty)
  }

  @Test("Tagged paths are unique and go ahead of the first message")
  func tags() async throws {
    let store = try await completions(RouteServer())
    #expect(store.message("hi", harness: "claude-native") == "hi")
    store.addMention("a.swift")
    store.addMention("a.swift")
    store.addMention("")
    #expect(store.mentions == ["a.swift"])
    let sent = store.message("hi", harness: "claude-native")
    #expect(sent.contains("a.swift"))
    #expect(sent.hasSuffix("hi"))
    store.removeMention("a.swift")
    #expect(store.mentions.isEmpty)
    store.addMention("b")
    store.clearMentions()
    store.clearMentions()
    #expect(store.mentions.isEmpty)
  }

  @Test("Paths show relative to the folder, and absolute outside it")
  func relativePaths() {
    #expect(LaunchCompletionsStore.relative("/a/b/c", to: "/a") == "b/c")
    #expect(LaunchCompletionsStore.relative("/x/y", to: "/a") == "/x/y")
    #expect(LaunchCompletionsStore.relative("/x/y", to: "/") == "x/y")
  }
}
