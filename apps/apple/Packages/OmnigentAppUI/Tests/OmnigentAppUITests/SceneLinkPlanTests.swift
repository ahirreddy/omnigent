import Foundation
import OmnigentDeepLinks
import Testing

@testable import OmnigentAppUI

@Suite("Scene deep-link plans")
struct SceneLinkPlanTests {
  private let local: URL
  private let team: URL

  init() throws {
    local = try #require(URL(string: "http://127.0.0.1:6767"))
    team = try #require(URL(string: "https://team.example.com/omnigent"))
  }

  private func link(_ raw: String) throws -> OmnigentDeepLink {
    try OmnigentDeepLink(parsing: raw)
  }

  @Test("a link to the signed-in server opens its session in place")
  func sameServer() throws {
    let plan = SceneLinkPlan.plan(
      try link("omnigent://127.0.0.1:6767/c/abc"), sceneServer: local, isReady: true,
      knownServers: [])
    #expect(plan == .apply(.conversation(sessionID: "abc")))
  }

  @Test("a link to the server the scene is connecting to waits for the sign-in")
  func connecting() throws {
    let plan = SceneLinkPlan.plan(
      try link("omnigent://127.0.0.1:6767/c/abc"), sceneServer: local, isReady: false,
      knownServers: [])
    #expect(plan == .applyWhenReady(.conversation(sessionID: "abc")))
  }

  @Test("an invite applies while the scene still signs in")
  func inviteBeforeSignIn() throws {
    let plan = SceneLinkPlan.plan(
      try link("omnigent://127.0.0.1:6767/register?invite=tok"), sceneServer: local,
      isReady: false, knownServers: [])
    #expect(plan == .apply(.register(invite: "tok")))
  }

  @Test("a link to a recent server switches to its recorded URL, mount included")
  func knownServer() throws {
    let plan = SceneLinkPlan.plan(
      try link("omnigent://team.example.com/c/abc"), sceneServer: local, isReady: true,
      knownServers: [local, team])
    #expect(plan == .switchServer(team, .conversation(sessionID: "abc")))
  }

  @Test("a link to a never-used server asks first, with or without a current server")
  func unknownServer() throws {
    let unknown = try link("omnigent://other.example.com/c/abc")
    #expect(
      SceneLinkPlan.plan(unknown, sceneServer: local, isReady: true, knownServers: [team])
        == .confirm)
    #expect(
      SceneLinkPlan.plan(unknown, sceneServer: nil, isReady: false, knownServers: []) == .confirm)
  }

  @Test("the scene on the server list switches to a recent server")
  func fromServerList() throws {
    let plan = SceneLinkPlan.plan(
      try link("omnigent://127.0.0.1:6767/"), sceneServer: nil, isReady: false,
      knownServers: [try #require(URL(string: "not a server")), local])
    #expect(plan == .switchServer(local, .home))
  }

  @Test("server URLs match ignoring case and trailing slashes, never when missing")
  func serverURLsMatch() throws {
    let spelled = try #require(URL(string: "HTTP://127.0.0.1:6767//"))
    #expect(ServerSession.sameServer(spelled, local))
    #expect(!ServerSession.sameServer(local, team))
    #expect(!ServerSession.sameServer(nil, local))
    #expect(!ServerSession.sameServer(nil, nil))
  }

  @Test("invite links keep the workspace mount and drop trailing slashes")
  func inviteLink() throws {
    let mounted = try #require(URL(string: "https://team.example.com/omnigent/"))
    #expect(
      SceneLinkPlan.inviteLink(server: mounted, invite: "a b")
        == "https://team.example.com/omnigent/register?invite=a%20b")
    #expect(
      SceneLinkPlan.inviteLink(server: local, invite: "tok")
        == "http://127.0.0.1:6767/register?invite=tok")
  }
}
