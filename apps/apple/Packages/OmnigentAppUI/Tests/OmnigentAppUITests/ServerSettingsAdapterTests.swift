import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

private func info(
  admin: Bool, singleUser: Bool = false, accounts: Bool = false, mcp: Bool = false,
  connections: [String] = []
) -> ServerSettingsInfo {
  ServerSettingsInfo(
    userId: "ada", isAdmin: admin, singleUser: singleUser, accountsEnabled: accounts,
    mcpRegistry: mcp, connections: connections, archiveWorktreeCleanup: false)
}

@Suite("Server settings adapter")
struct ServerSettingsAdapterTests {
  @Test("panes follow what the server offers and the caller may manage")
  func panes() {
    #expect(ServerSettingsAdapter.panes(nil) == [.git, .importSessions, .archived])
    #expect(
      ServerSettingsAdapter.panes(info(admin: false))
        == [.git, .importSessions, .archived])
    #expect(
      ServerSettingsAdapter.panes(info(admin: true, singleUser: true))
        == [.git, .importSessions, .policies, .archived],
      "no Members or Sharing without other users")
    #expect(
      ServerSettingsAdapter.panes(
        info(admin: true, accounts: true, mcp: true, connections: ["github"]))
        == [
          .account, .mcp, .integrations, .git, .importSessions, .members, .policies, .sharing,
          .archived,
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
}
