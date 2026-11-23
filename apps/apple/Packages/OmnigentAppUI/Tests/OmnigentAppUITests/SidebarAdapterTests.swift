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

  @Test("Others' automation runs join the automation folder, a placeholder until it exists")
  func sharedRuns() {
    var run = session("run", owner: "other")
    run.isAutomationRun = true
    var pinnedRun = session("pinned-run", owner: "other", pinned: true)
    pinnedRun.isAutomationRun = true
    var ownRun = session("own-run", owner: "me")
    ownRun.isAutomationRun = true
    let sessions = [run, pinnedRun, ownRun, session("theirs", owner: "other")]
    func folders(
      _ projects: [ProjectSummary], show: SessionShowScope = .all, manualOrder: Bool = false
    ) -> [SessionProject] {
      SidebarAdapter.layout(
        sessions: sessions, projects: projects, display: SessionDisplayOptions(show: show),
        members: { rows in
          projectMembers(projects: projects, sessions: rows, viewerId: "me")
        }, isOwned: isOwned, manualOrder: manualOrder
      ).projects
    }
    let named = [
      ProjectSummary(id: "p1", name: "Alpha", icon: nil),
      ProjectSummary(id: "p2", name: "Zeta", icon: nil),
    ]
    let placed = folders(named)
    #expect(placed.map(\.name) == ["Alpha", "Omnigent Automation", "Zeta"])
    #expect(placed.map(\.isPlaceholder) == [false, true, false])
    #expect(placed[1].sessionIds == ["run"])
    #expect(folders(named, manualOrder: true).last?.isPlaceholder == true)
    // Shared views list them among their rows; My sessions files them too.
    #expect(!folders(named, show: .shared).contains { $0.isPlaceholder })
    #expect(folders(named, show: .mine).contains { $0.isPlaceholder })

    let real = folders([ProjectSummary(id: "p3", name: "Omnigent Automation", icon: nil)])
    #expect(real.count == 1 && !real[0].isPlaceholder && real[0].sessionIds == ["run"])
  }

  @Test("Row info marks shared sessions and names the workspace folder")
  func rowInfo() {
    let info = SidebarAdapter.rowInfo(session("a", owner: "other"), isOwned: false)
    #expect(info.isShared)
    #expect(info.repo == "repo")
    #expect(info.createdAt == 5)
    #expect(info.createdBy == "other")
    #expect(SidebarAdapter.rowInfo(session("b", owner: "me"), isOwned: true).createdBy == "You")
    // Without permissions there is no owner to name.
    #expect(SidebarAdapter.rowInfo(session("c"), isOwned: true).createdBy == nil)
    #expect(SidebarAdapter.repoName("Local server") == nil)
  }

  @Test("A workspace on another machine is named from its text, without a lookup on this one")
  func repoNameOfARemotePath() {
    #expect(SidebarAdapter.repoName("/home/ubuntu/src/omnigent") == "omnigent")
    #expect(SidebarAdapter.repoName("/home/ubuntu/src/omnigent/") == "omnigent")
    #expect(SidebarAdapter.repoName("~/src/notes") == "notes")
    #expect(SidebarAdapter.repoName("/") == nil)
    // macOS answers a lookup under `/home` through its automounter in about 10 ms, so a
    // sidebar of names that touched the disk would take seconds here.
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      for index in 0..<2_000 {
        #expect(SidebarAdapter.repoName("/home/nobody/src/repo\(index)") == "repo\(index)")
      }
    }
    #expect(elapsed < .seconds(1))
  }

  @Test("Row info names the environment once the hosts are read, and carries the draft marker")
  func rowEnvironmentAndDraft() {
    func hosted(_ hostID: String?) -> OmnigentCoreFFI.SessionSummary {
      var summary = session("s")
      summary.configuration = OmnigentCoreFFI.SessionConfiguration(
        agentId: nil, harness: nil, wrapper: nil, modelOverride: nil, baseModel: nil, effort: nil,
        modelReported: nil, effortReported: nil, models: [], hostId: hostID, hostOnline: nil,
        runnerOnline: nil, runnerBound: nil, hostResumable: nil, parentId: nil, routingMode: nil,
        approvalMode: nil)
      return summary
    }
    let environments: [String: SessionEnvironment] = [
      "mac": .thisMachine, "box": .sandbox(label: "Modal Sandbox"),
    ]
    func environment(_ hostID: String?) -> String? {
      SidebarAdapter.rowInfo(hosted(hostID), isOwned: true, environments: environments)
        .environment
    }
    #expect(environment("mac") == "This Mac")
    #expect(environment("box") == "Modal Sandbox")
    #expect(environment("elsewhere") == "Remote")
    #expect(environment(nil) == "Local machine")
    #expect(SidebarAdapter.rowInfo(hosted("mac"), isOwned: true).runsOnHost)
    #expect(!SidebarAdapter.rowInfo(hosted(nil), isOwned: true).runsOnHost)
    // Unknown until the hosts are read.
    #expect(SidebarAdapter.rowInfo(hosted("mac"), isOwned: true).environment == nil)
    #expect(SidebarAdapter.rowInfo(session("s"), isOwned: true, hasDraft: true).hasDraft)
    // The core names this Mac as the only online machine of a local server.
    let hosts = [
      CreationHost(
        hostId: "mac", name: "Mac", status: "online", sandboxProvider: nil,
        configuredHarnesses: nil, isAvailable: true)
    ]
    #expect(
      hostEnvironments(hosts: hosts, serverUrl: "http://127.0.0.1:6767", thisMachineHostId: nil)
        .map(\.environment) == [.thisMachine])
    #expect(
      hostEnvironments(hosts: hosts, serverUrl: "https://omni.example.com", thisMachineHostId: nil)
        .map(\.environment) == [.remote])
  }

  /// Whether the row of a session on host `sbx`, its runner connected, says its sandbox is
  /// alive once `adjust` changes it. `environments` is the host list, empty until it is read.
  private func hasLiveSandbox(
    status: OmnigentCoreFFI.SessionListStatus = .idle,
    environments: [String: SessionEnvironment] = [
      "sbx": .sandbox(label: "Modal Sandbox"), "mac": .thisMachine,
    ],
    _ adjust: (inout OmnigentCoreFFI.SessionConfiguration) -> Void = { _ in }
  ) -> Bool {
    var configuration = ConversationFixtures.configuration(harness: "codex-native")
    configuration.hostId = "sbx"
    adjust(&configuration)
    return SidebarAdapter.rowInfo(
      ConversationFixtures.summary("conv", status: status, configuration: configuration),
      isOwned: true, environments: environments
    ).hasLiveSandbox
  }

  /// Unbound, as before the sandbox's host is up, with a launch at `stage`.
  private func launched(_ stage: SandboxLaunchStage) -> (
    inout OmnigentCoreFFI.SessionConfiguration
  ) -> Void {
    { configuration in
      configuration.hostId = nil
      configuration.hostOnline = nil
      configuration.runnerOnline = false
      configuration.sandboxLaunch = SandboxLaunch(
        stage: stage, provider: "example", details: nil, error: nil)
    }
  }

  @Test("Row info says whether the session's own sandbox is alive, from the list alone")
  func rowSandboxLiveness() {
    // Its runner connected, or the sandbox up with its agent asleep.
    let agentAsleep = hasLiveSandbox { $0.runnerOnline = false }
    #expect(hasLiveSandbox())
    #expect(agentAsleep)
    // Stopped or not reported, it rests; a turn under way wakes it.
    let stopped: (inout OmnigentCoreFFI.SessionConfiguration) -> Void = {
      $0.hostOnline = false
      $0.runnerOnline = false
    }
    #expect(!hasLiveSandbox(stopped))
    #expect(hasLiveSandbox(status: .running, stopped))
    let unreported = hasLiveSandbox {
      $0.hostOnline = nil
      $0.runnerOnline = nil
    }
    #expect(!unreported)
    // A launch under way or waiting on the user is alive; a failed one is not.
    #expect(hasLiveSandbox(launched(.provisioning)))
    #expect(hasLiveSandbox(launched(.actionRequired)))
    #expect(!hasLiveSandbox(launched(.failed)))
    // A machine, an unread host list and no configuration have none.
    let onMachine = hasLiveSandbox { $0.hostId = "mac" }
    #expect(!onMachine)
    #expect(!hasLiveSandbox(environments: [:]))
    #expect(!SidebarAdapter.rowInfo(session("s"), isOwned: true).hasLiveSandbox)
  }

  @Test("A child session's row follows the sandbox of its family's top session")
  func childSandboxLiveness() {
    let environments: [String: SessionEnvironment] = ["sbx": .sandbox(label: "Modal Sandbox")]
    func row(_ id: String, parent: String?, hostOnline: Bool = false)
      -> OmnigentCoreFFI.SessionSummary
    {
      var configuration = ConversationFixtures.configuration(harness: "codex-native")
      // A child reports no host of its own, and its runner says nothing of the sandbox.
      configuration.hostId = parent == nil ? "sbx" : nil
      configuration.hostOnline = parent == nil ? hostOnline : nil
      configuration.runnerOnline = parent != nil
      configuration.parentId = parent
      return ConversationFixtures.summary(id, configuration: configuration)
    }
    func isAlive(_ rows: [OmnigentCoreFFI.SessionSummary]) -> Bool {
      let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
      return SidebarAdapter.rowInfo(
        rows[rows.count - 1], isOwned: true, environments: environments, lookup: { byID[$0] }
      ).hasLiveSandbox
    }
    let online = row("top", parent: nil, hostOnline: true)
    let offline = row("top", parent: nil)
    let child = row("child", parent: "top")
    let grandchild = row("grandchild", parent: "child")
    #expect(isAlive([online, child]))
    #expect(isAlive([online, child, grandchild]))
    #expect(!isAlive([offline, child]))
    #expect(!isAlive([offline, child, grandchild]))
    // A parent the list has not loaded says nothing.
    #expect(!isAlive([child]))
    // A loop of parents ends.
    let loop = row("loop", parent: "loop")
    #expect(!isAlive([loop]))
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
      organizationServers: [try #require(URL(string: "https://OMNI.example.com/"))],
      switchTo: { _ in }, addServer: {})
    #expect(switching.choices.map(\.id) == ["http://127.0.0.1:6767", "https://omni.example.com"])
    // The organization's servers are grouped apart from recents.
    #expect(switching.choices.map(\.isOrganization) == [false, true])
  }
}
