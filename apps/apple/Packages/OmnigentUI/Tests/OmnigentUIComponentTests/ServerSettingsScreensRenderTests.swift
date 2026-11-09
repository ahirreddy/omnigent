#if os(macOS)
  import Foundation
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Server settings panes with hostile data", .serialized)
  struct ServerSettingsScreensRenderTests {
    nonisolated static let screens: [ScreenCase] = [
      ScreenCase("password-pane", realistic: true, narrowOnly: true) {
        GroupedFormHost { ChangePasswordPane(actions: everyAction) }
      },
      ScreenCase("mcp-realistic", realistic: true) {
        GroupedFormHost {
          MCPPane(services: PreviewData.serverSettings.mcpServices, actions: everyAction)
        }
      },
      ScreenCase("mcp-empty", narrowOnly: true) {
        GroupedFormHost { MCPPane(services: [], actions: ServerSettingsActions()) }
      },
      ScreenCase("mcp-hostile") {
        GroupedFormHost {
          MCPPane(
            services: hostileServices, actions: everyAction, errorMessage: HostileData.bidirectional
          )
        }
      },
      ScreenCase("integrations-realistic", realistic: true) {
        GroupedFormHost {
          IntegrationsPane(
            connections: PreviewData.serverSettings.connections, actions: everyAction)
        }
      },
      ScreenCase("integrations-empty", narrowOnly: true) {
        GroupedFormHost { IntegrationsPane(connections: [], actions: ServerSettingsActions()) }
      },
      ScreenCase("integrations-hostile") {
        GroupedFormHost { IntegrationsPane(connections: hostileConnections, actions: everyAction) }
      },
      ScreenCase("git-pane", realistic: true, narrowOnly: true) {
        GroupedFormHost { GitSettingsPane(archiveWorktreeCleanup: true) }
      },
      ScreenCase("import-realistic", realistic: true) {
        GroupedFormHost {
          ImportSessionsPane(
            hosts: PreviewData.serverSettings.importHosts,
            sources: PreviewData.serverSettings.importSources, actions: everyAction)
        }
      },
      ScreenCase("import-empty", narrowOnly: true) {
        GroupedFormHost {
          ImportSessionsPane(hosts: [], sources: [], actions: ServerSettingsActions())
        }
      },
      ScreenCase("import-hostile") {
        GroupedFormHost {
          ImportSessionsPane(
            hosts: hostileChoices, sources: hostileChoices, actions: everyAction)
        }
      },
      ScreenCase("members-realistic", realistic: true) {
        GroupedFormHost {
          MembersPane(members: PreviewData.serverSettings.members, actions: everyAction)
        }
      },
      ScreenCase("members-empty", narrowOnly: true) {
        GroupedFormHost { MembersPane(members: [], actions: ServerSettingsActions()) }
      },
      ScreenCase("members-hostile") {
        GroupedFormHost {
          MembersPane(
            members: hostileMembers, actions: everyAction, errorMessage: HostileData.unbroken)
        }
      },
      ScreenCase("policies-realistic", realistic: true) {
        GroupedFormHost {
          PoliciesPane(policies: PreviewData.serverSettings.policies, actions: everyAction)
        }
      },
      ScreenCase("policies-empty", narrowOnly: true) {
        GroupedFormHost { PoliciesPane(policies: [], actions: ServerSettingsActions()) }
      },
      ScreenCase("policies-hostile") {
        GroupedFormHost {
          PoliciesPane(
            policies: hostilePolicies, templates: hostileTemplates, actions: everyAction,
            errorMessage: HostileData.unbroken)
        }
      },
      ScreenCase("sharing-realistic", realistic: true) {
        GroupedFormHost {
          SharingPane(sharing: PreviewData.serverSettings.sharing, actions: everyAction)
        }
      },
      ScreenCase("sharing-not-loaded", narrowOnly: true) {
        GroupedFormHost { SharingPane(sharing: nil, actions: ServerSettingsActions()) }
      },
      ScreenCase("sharing-hostile") {
        GroupedFormHost { SharingPane(sharing: hostileSharing, actions: everyAction) }
      },
      ScreenCase("invite-sheet", realistic: true, narrowOnly: true) {
        InviteMemberSheet(invite: { _ in nil }, errorMessage: HostileData.unbroken)
      },
      ScreenCase("add-policy-realistic", realistic: true) {
        AddPolicySheet(
          templates: [
            PolicyTemplate(
              id: "h1", name: "Ask before pushing", detail: "Pauses before a push.",
              suggestedName: "ask", params: [])
          ], add: { _, _, _ in true }, errorMessage: nil)
      },
      ScreenCase("add-policy-empty", narrowOnly: true) {
        AddPolicySheet(templates: [], add: { _, _, _ in false }, errorMessage: "")
      },
      ScreenCase("add-policy-hostile") {
        AddPolicySheet(
          templates: hostileTemplates, add: { _, _, _ in false },
          errorMessage: HostileData.unbroken)
      },
      ScreenCase("archived-realistic", realistic: true) {
        GroupedFormHost {
          ArchivedSessionsPane(
            sessions: realisticArchive, info: [:], projects: [], hasMore: true,
            actions: everyAction)
        }
      },
      ScreenCase("archived-empty", realistic: true, narrowOnly: true) {
        GroupedFormHost {
          ArchivedSessionsPane(
            sessions: [], info: [:], projects: [], hasMore: false,
            actions: ServerSettingsActions())
        }
      },
      ScreenCase("archived-hostile") {
        GroupedFormHost {
          ArchivedSessionsPane(
            sessions: hostileArchive, info: hostileArchiveInfo, projects: hostileChoices,
            hasMore: true, actions: everyAction)
        }
      },
    ]

    @Test("renders without crashing or hanging", arguments: screens)
    func render(screen: ScreenCase) throws {
      try ScreenRenderer.check(screen)
    }

    @Test("a stored retention marks old sessions expired, offering Delete Expired")
    func expiredRow() throws {
      UserDefaults.standard.set("7", forKey: ArchivedRetention.key)
      defer { UserDefaults.standard.removeObject(forKey: ArchivedRetention.key) }
      try ScreenRenderer.check(
        ScreenCase("archived-past-retention", realistic: true, narrowOnly: true) {
          GroupedFormHost {
            ArchivedSessionsPane(
              sessions: Array(Self.hostileArchive.prefix(6)), info: Self.hostileArchiveInfo,
              projects: [], hasMore: true, actions: Self.everyAction)
          }
        })
    }
  }

  extension ServerSettingsScreensRenderTests {
    private static var everyAction: ServerSettingsActions {
      var actions = ServerSettingsActions()
      actions.load = { _ in }
      actions.setHarnessEnabled = { _, _ in }
      actions.connectMCP = { _, _ in true }
      actions.disconnectMCP = { _ in }
      actions.testMCP = { _ in "ok" }
      actions.openInBrowser = { _ in }
      actions.disconnectProvider = { _ in }
      actions.importSessions = { _, _, _, _ in "Imported 3" }
      actions.changePassword = { _, _ in true }
      actions.signOut = {}
      actions.openSession = { _ in }
      actions.resetPassword = { _ in "new" }
      actions.removeMember = { _ in }
      actions.invite = { _ in MemberInviteLink(url: "https://example.com/i") }
      actions.addPolicy = { _, _, _ in true }
      actions.setPolicyEnabled = { _, _ in }
      actions.deletePolicy = { _ in }
      actions.changeSharing = { _ in }
      actions.unarchive = { _ in }
      actions.delete = { _ in }
      actions.loadMoreArchived = {}
      return actions
    }

    private static var hostileServices: [MCPServiceRow] {
      (0..<HostileData.formRowCount).map { index in
        MCPServiceRow(
          id: "\(index)", name: HostileData.text(index), detail: HostileData.text(index + 1),
          isConnected: index.isMultiple(of: 2),
          tools: index.isMultiple(of: 5)
            ? (0..<HostileData.formRowCount).map(HostileData.text) : [],
          acceptsToken: index.isMultiple(of: 3), canDisconnect: index % 3 == 1,
          connectsInBrowser: index % 3 == 2)
      }
    }

    private static var hostileConnections: [ProviderConnectionRow] {
      (0..<HostileData.formRowCount).map { index in
        ProviderConnectionRow(
          id: "\(index)", name: HostileData.text(index), isConnected: index.isMultiple(of: 2),
          account: index.isMultiple(of: 4) ? nil : HostileData.text(index + 1))
      }
    }

    private static var hostileMembers: [ServerMember] {
      (0..<HostileData.formRowCount).map { index in
        ServerMember(
          id: "\(index)\(HostileData.text(index))", detail: HostileData.text(index + 1),
          isAdmin: index.isMultiple(of: 2), canResetPassword: index.isMultiple(of: 3),
          canRemove: index % 3 == 1)
      }
    }

    private static var hostilePolicies: [ServerSettingRow] {
      (0..<HostileData.formRowCount).map { index in
        ServerSettingRow(
          id: "\(index)", name: HostileData.text(index), detail: HostileData.text(index + 1),
          isEnabled: index.isMultiple(of: 2), isReadOnly: index.isMultiple(of: 3))
      }
    }

    private static var hostileChoices: [SettingChoice] {
      (0..<HostileData.formRowCount).map { SettingChoice(id: "\($0)", title: HostileData.text($0)) }
    }

    private static var hostileSharing: SharingViewState {
      SharingViewState(
        mode: "missing", modeChoices: hostileChoices, modeEditable: true, publicSharing: true,
        publicSharingEditable: false, publicLevel: HostileData.controlCharacters,
        publicLevelChoices: hostileChoices, publicLevelEditable: true,
        defaultPublic: HostileData.unbroken, defaultPublicChoices: [], defaultPublicEditable: false)
    }

    private static var hostileTemplates: [PolicyTemplate] {
      (0..<HostileData.formRowCount).map { index in
        PolicyTemplate(
          id: "\(index)", name: HostileData.text(index), detail: HostileData.text(index + 1),
          suggestedName: HostileData.text(index + 2),
          params: [PolicyTemplate.Param(id: "p", kind: .text)])
      }
    }

    private static var realisticArchive: [SessionSummary] {
      PreviewData.sessions.prefix(4).enumerated().map { index, session in
        var archived = session
        archived.updatedAt = Int64(Date.now.timeIntervalSince1970) - Int64(index) * 86_400 * 9
        return archived
      }
    }

    /// Times from either end of the 64-bit range, out of order, so a date group repeats.
    private static var hostileArchive: [SessionSummary] {
      let times: [Int64] = [Int64.max, Int64.min, 0, -1, 1_793_880_000, Int64.max]
      return (0..<HostileData.formRowCount).map { index in
        SessionSummary(
          id: "\(index)", title: HostileData.text(index), preview: HostileData.text(index + 1),
          updatedAt: times[index % times.count], workspace: HostileData.text(index + 2),
          agentName: HostileData.text(index + 3))
      }
    }

    private static var hostileArchiveInfo: [String: ArchivedSessionInfo] {
      Dictionary(
        uniqueKeysWithValues: (0..<HostileData.formRowCount).map { index in
          (
            "\(index)",
            ArchivedSessionInfo(
              projectID: index.isMultiple(of: 2) ? "0" : nil,
              archivedAt: index.isMultiple(of: 2) ? Int64.min : Int64.max,
              canDelete: index.isMultiple(of: 3))
          )
        })
    }
  }

  @Suite("Archived sessions with hostile dates")
  struct ArchivedSessionsHostileTests {
    private let now = Date(timeIntervalSince1970: 1_793_880_000)

    private var calendar: Calendar {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
      return calendar
    }

    private func session(_ id: String, updatedAt: Int64) -> SessionSummary {
      SessionSummary(id: id, title: id, updatedAt: updatedAt)
    }

    @Test("sessions out of order form a new group each time the label changes")
    func outOfOrder() {
      let today = Int64(now.timeIntervalSince1970)
      let groups = ArchivedGroup.groups(
        [
          session("a", updatedAt: today), session("b", updatedAt: today - 86_400 * 20),
          session("c", updatedAt: today),
        ], now: now, calendar: calendar)
      #expect(groups.map(\.label) == ["Today", "Previous 30 days", "Today"])
    }

    @Test("the far ends of the 64-bit range still get a label")
    func extremeTimes() {
      let groups = ArchivedGroup.groups(
        [session("future", updatedAt: Int64.max), session("past", updatedAt: Int64.min)], now: now,
        calendar: calendar)
      #expect(groups.count == 2)
      #expect(groups.first?.label == "Today", "anything after midnight counts as today")
    }

    @Test(
      "retention ignores what the web wouldn't write", arguments: ["", "0", "-7", "7.5", "abc"])
    func invalidRetention(stored: String) {
      #expect(ArchivedRetention.days(stored) == nil)
    }

    @Test("a session is expired only with facts, past the cutoff, when it can be deleted")
    func expired() {
      let cutoff = Int64(now.timeIntervalSince1970) - 7 * 86_400
      let sessions = ["old", "new", "theirs", "unknown"].map { session($0, updatedAt: 0) }
      let info = [
        "old": ArchivedSessionInfo(archivedAt: cutoff - 1, canDelete: true),
        "new": ArchivedSessionInfo(archivedAt: cutoff, canDelete: true),
        "theirs": ArchivedSessionInfo(archivedAt: Int64.min, canDelete: false),
      ]
      #expect(ArchivedRetention.expired(sessions, info: info, days: 7, now: now) == ["old"])
      #expect(ArchivedRetention.expired(sessions, info: info, days: nil, now: now).isEmpty)
    }
  }
#endif
