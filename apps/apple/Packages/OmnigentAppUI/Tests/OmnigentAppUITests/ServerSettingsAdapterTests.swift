import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

private func info(
  admin: Bool, singleUser: Bool = false, accounts: Bool = false, mcp: Bool = false,
  connections: [String] = [], customAgents: Bool = false
) -> ServerSettingsInfo {
  ServerSettingsInfo(
    userId: "ada", isAdmin: admin, singleUser: singleUser, accountsEnabled: accounts,
    mcpRegistry: mcp, connections: connections, archiveWorktreeCleanup: false,
    customAgents: customAgents)
}

@Suite("Server settings adapter")
struct ServerSettingsAdapterTests {
  @Test("panes follow what the server offers and the caller may manage")
  func panes() {
    #expect(ServerSettingsAdapter.panes(nil) == [.harnesses, .git, .importSessions, .archived])
    #expect(
      ServerSettingsAdapter.panes(info(admin: false))
        == [.harnesses, .git, .importSessions, .archived],
      "Custom Agents needs the server's custom_agents_settings_ui and agent_install")
    #expect(
      ServerSettingsAdapter.panes(info(admin: true, singleUser: true))
        == [.harnesses, .git, .importSessions, .policies, .archived],
      "no Members or Sharing without other users")
    #expect(
      ServerSettingsAdapter.panes(
        info(
          admin: true, accounts: true, mcp: true, connections: ["github"], customAgents: true))
        == [
          .account, .harnesses, .customAgents, .mcp, .integrations, .git, .importSessions,
          .members, .policies, .sharing, .archived,
        ])
  }

  @Test("members can be reset and removed only on password servers, never yourself")
  func members() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let caller = ServerMemberRecord(
      id: "ada", isAdmin: true, createdAt: nil, lastLoginAt: nil, hasPassword: true)
    let other = ServerMemberRecord(
      id: "bob", isAdmin: false, createdAt: nil, lastLoginAt: 999_000, hasPassword: true)
    let accounts = info(admin: true, accounts: true)
    #expect(!ServerSettingsAdapter.member(caller, info: accounts, now: now).canRemove)
    let bob = ServerSettingsAdapter.member(other, info: accounts, now: now)
    #expect(bob.canRemove && bob.canResetPassword)
    #expect(bob.detail.hasPrefix("Last signed in"))
    #expect(
      ServerSettingsAdapter.member(caller, info: accounts, now: now).detail == "Never signed in")
    let sso = ServerSettingsAdapter.member(other, info: info(admin: true), now: now)
    #expect(!sso.canRemove && !sso.canResetPassword)
  }

  @Test("sharing keeps an unlisted current value selectable and sends one field")
  func sharing() {
    let choices = ServerSettingsAdapter.choices(["on", "off"], current: "read_only")
    #expect(choices.map(\.id) == ["read_only", "on", "off"])
    #expect(ServerSettingsAdapter.update(.publicSharing(false)).publicSharing == false)
    #expect(ServerSettingsAdapter.update(.publicSharing(false)).mode == nil)
  }

  @Test("an import tally reads as one line")
  func importSummary() {
    let result = ImportResultRecord(
      imported: 3, alreadyImported: 1, failed: 1, failures: ["x: unreadable"])
    #expect(
      ServerSettingsAdapter.importSummary(result)
        == "Imported 3, 1 already imported, 1 failed. x: unreadable")
  }

  @Test("registry handlers become add-policy templates; invites keep their expiry")
  func policyTemplates() {
    let entry = PolicyRegistryEntry(
      handler: "p.loop", name: "Detect Loop", description: "Stops loops", isFactory: true,
      params: [
        PolicyParam(
          key: "pii", kind: .multiChoice, description: "Kinds", defaultValue: "ssn",
          options: ["ssn", "email"], required: false)
      ],
      suggestedName: "detect_loop")
    let template = ServerSettingsAdapter.policyTemplate(entry)
    #expect(template.id == "p.loop" && template.suggestedName == "detect_loop")
    #expect(template.params.first?.kind == .multiChoice)
    #expect(template.params.first?.options == ["ssn", "email"])
    #expect(template.matches("LOOP") && template.matches("stops") && !template.matches("ssh"))
    let link = ServerSettingsAdapter.inviteLink(
      MemberInvite(url: "https://x/register?invite=t", expiresAt: 60, isAdmin: false))
    #expect(link.expiresAt == Date(timeIntervalSince1970: 60))
  }

  @Test("an SSO sign-in shows Account, with Sign out but no password change")
  func ssoAccount() {
    var sso = info(admin: false)
    sso.hasLoginSession = true
    #expect(ServerSettingsAdapter.panes(sso).first == .account)
    #expect(ServerSettingsAdapter.panes(info(admin: false)).first != .account)
  }

  @Test("archived sessions: only your own can be deleted; projects are named and sorted")
  func archivedFacts() {
    let mine = archivedSession("a", owner: nil, projectID: "p_2")
    let ada = archivedSession("b", owner: "ada", projectLabel: "Legacy")
    let bob = archivedSession("c", owner: "bob", projectID: "p_1")
    #expect(ServerSettingsAdapter.archivedInfo(mine, userID: "ada").canDelete)
    #expect(ServerSettingsAdapter.archivedInfo(ada, userID: "ada").canDelete)
    #expect(!ServerSettingsAdapter.archivedInfo(bob, userID: "ada").canDelete)
    #expect(ServerSettingsAdapter.archivedInfo(ada, userID: "ada").projectID == "label:Legacy")
    let projects = [
      OmnigentCoreFFI.ProjectSummary(id: "p_1", name: "Zeta", icon: nil),
      OmnigentCoreFFI.ProjectSummary(id: "p_2", name: "Alpha", icon: nil),
    ]
    let choices = ServerSettingsAdapter.archivedProjects(
      [mine, ada, bob, mine], projects: projects)
    #expect(choices.map(\.title) == ["Alpha", "Legacy", "Zeta"])
    #expect(choices.map(\.id) == ["p_2", "label:Legacy", "p_1"])
  }

  @Test("a request for a server matches it ignoring case and a trailing slash")
  func requestedServer() {
    let ids = ["https://a.example.com", "http://127.0.0.1:6767"]
    #expect(ServerSettingsContainer.server("HTTPS://a.example.com/", in: ids) == ids[0])
    #expect(ServerSettingsContainer.server("https://b.example.com", in: ids) == nil)
    #expect(ServerSettingsContainer.server(nil, in: ids) == nil)
  }
}

@Suite("Settings navigation")
@MainActor
struct SettingsNavigatorTests {
  @Test("a server destination selects the Servers tab and leaves one request to take")
  func serverDestination() {
    let navigator = SettingsNavigator()
    #expect(navigator.tab == SettingsNavigator.generalTab)
    navigator.show(.server(url: "https://a.example.com", pane: .importSessions))
    #expect(navigator.tab == SettingsNavigator.serversTab)
    let request = navigator.takeServerRequest()
    #expect(request?.url == "https://a.example.com" && request?.pane == .importSessions)
    #expect(navigator.takeServerRequest() == nil)
    navigator.show(.tab(SettingsNavigator.terminalTab))
    #expect(navigator.tab == SettingsNavigator.terminalTab && navigator.serverRequest == nil)
  }

  @Test("asking twice for the same server is two requests")
  func repeatedRequestsDiffer() {
    let navigator = SettingsNavigator()
    navigator.show(.server(url: nil, pane: nil))
    let first = navigator.takeServerRequest()
    navigator.show(.server(url: nil, pane: nil))
    #expect(first != navigator.takeServerRequest())
  }

  @Test("opening Settings moves the navigator, then shows the window")
  func openAction() {
    let navigator = SettingsNavigator()
    var opened: [String] = []
    let action = OpenSettingsDestinationAction { destination in
      navigator.show(destination)
      opened.append(navigator.tab)
    }
    action(.tab(SettingsNavigator.appearanceTab))
    #expect(opened == [SettingsNavigator.appearanceTab])
  }
}

private func archivedSession(
  _ id: String, owner: String?, projectID: String? = nil, projectLabel: String? = nil
) -> OmnigentCoreFFI.SessionSummary {
  var session = OmnigentCoreFFI.SessionSummary(
    id: id, title: id, preview: "", status: .idle, isReadOnly: false, updatedAt: 100,
    workspace: "", agentName: "", isPinned: false, isArchived: true, permissionLevel: 4,
    failureMessage: nil, canRename: true, canPin: true, canArchive: true)
  session.owner = owner
  session.projectId = projectID
  session.projectLabel = projectLabel
  return session
}
