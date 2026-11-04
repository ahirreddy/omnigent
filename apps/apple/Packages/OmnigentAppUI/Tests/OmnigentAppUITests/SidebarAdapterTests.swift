import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
struct SidebarAdapterTests {
  private func session(
    _ id: String, owner: String? = nil, pinned: Bool = false, project: String? = nil
  ) -> OmnigentCoreFFI.SessionSummary {
    OmnigentCoreFFI.SessionSummary(
      id: id, title: id, preview: "", status: .idle, pendingRequests: 0, isReadOnly: false,
      updatedAt: 0, workspace: "/Users/me/src/repo", agentName: "", isPinned: pinned,
      isArchived: false, permissionLevel: 4, failureMessage: nil, canRename: true, canPin: true,
      canArchive: true, configuration: nil, terminalFirst: false, createdAt: 5, owner: owner,
      projectId: project, projectLabel: nil, canStop: false)
  }

  private func members(_ sessions: [OmnigentCoreFFI.SessionSummary]) -> [[String]] {
    projectMembers(
      projects: [ProjectSummary(id: "p1", name: "Alpha", icon: "🔥")], sessions: sessions,
      viewerId: "me")
  }

  private func isOwned(_ session: OmnigentCoreFFI.SessionSummary) -> Bool {
    sessionIsOwnedBy(session: session, viewerId: "me")
  }

  @Test("Folders hold the viewer's unpinned sessions; Show scopes the rest, never pins")
  func layoutScopes() {
    let sessions = [
      session("pin", owner: "other", pinned: true), session("filed", owner: "me", project: "p1"),
      session("mine", owner: "me"), session("theirs", owner: "other"),
    ]
    let projects = [ProjectSummary(id: "p1", name: "Alpha", icon: "🔥")]
    func shown(_ show: SessionShowScope) -> [String] {
      SidebarAdapter.layout(
        sessions: sessions, projects: projects,
        display: SessionDisplayOptions(show: show), members: members, isOwned: isOwned
      ).sessions.map(\.id)
    }
    #expect(shown(.all) == ["pin", "filed", "mine", "theirs"])
    #expect(shown(.mine) == ["pin", "filed", "mine"])
    #expect(shown(.shared) == ["pin", "filed", "theirs"])
    let folders = SidebarAdapter.layout(
      sessions: sessions, projects: projects, display: SessionDisplayOptions(),
      members: members, isOwned: isOwned
    ).projects
    #expect(
      folders == [
        SessionProject(id: "p1", name: "Alpha", sessionIds: ["filed"], projectID: "p1", icon: "🔥")
      ])
    // Grouped views have no folders.
    let grouped = SidebarAdapter.layout(
      sessions: sessions, projects: projects,
      display: SessionDisplayOptions(groupBy: .status), members: members, isOwned: isOwned)
    #expect(grouped.projects.isEmpty)
  }

  @Test("Row info marks shared sessions and names the workspace folder")
  func rowInfo() {
    let info = SidebarAdapter.rowInfo(session("a", owner: "other"), isOwned: false)
    #expect(info.isShared)
    #expect(info.repo == "repo")
    #expect(info.createdAt == 5)
    #expect(SidebarAdapter.repoName("Local server") == nil)
  }

  @Test("Display options persist and bad data falls back to the defaults")
  func displayDefaults() throws {
    let defaults = try #require(UserDefaults(suiteName: "SidebarAdapterTests"))
    defaults.removePersistentDomain(forName: "SidebarAdapterTests")
    #expect(SidebarDisplayDefaults.load(defaults) == SessionDisplayOptions())
    let options = SessionDisplayOptions(show: .mine, groupBy: .harness, details: [.branch])
    SidebarDisplayDefaults.save(options, defaults)
    #expect(SidebarDisplayDefaults.load(defaults) == options)
    defaults.set(Data("nope".utf8), forKey: SidebarDisplayDefaults.key)
    #expect(SidebarDisplayDefaults.load(defaults) == SessionDisplayOptions())
  }

  @Test("The switcher lists each known server once, matching the current one")
  func serverChoices() throws {
    let switching = ServerSwitching(
      servers: [
        try #require(URL(string: "http://127.0.0.1:6767/")),
        try #require(URL(string: "http://127.0.0.1:6767")),
        try #require(URL(string: "https://omni.example.com")),
      ],
      switchTo: { _ in }, addServer: {})
    #expect(switching.choices.map(\.id) == ["http://127.0.0.1:6767", "https://omni.example.com"])
  }
}
