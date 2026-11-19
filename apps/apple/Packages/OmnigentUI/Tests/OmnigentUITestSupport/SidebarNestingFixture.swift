import Foundation

@testable import OmnigentUIComponents

/// A sidebar with nesting at every level: Pinned holds a family (Release Rollout over Release
/// Notes) among childless pins; the Gateway folder holds an expanded family (Spoke Tests over
/// Plan Review), a collapsed one (Monitor Job) and a childless session, with one more under Show
/// more; Shared holds one session and Sessions a family (Research Lead over two members) beside a
/// childless one. Every row has the same harness, so their marks draw alike.
enum SidebarNestingFixture {
  static let project = SessionProject(
    id: "gateway", name: "Gateway",
    sessionIds: ["spokes", "plan", "monitor", "monitor-run", "internals", "extra"])
  static let collapsedProject = SessionProject(id: "tools", name: "Tooling", sessionIds: ["tool"])

  private static let rolloutFamily = SessionFamilyInfo(
    id: "rollout", representativeID: "rollout", representativeTitle: "Release Rollout",
    isPinned: true, pinnedAt: "1700000000000")
  private static let spokesFamily = SessionFamilyInfo(
    id: "spokes", representativeID: "spokes", representativeTitle: "Spoke Tests")
  private static let monitorFamily = SessionFamilyInfo(
    id: "monitor", representativeID: "monitor", representativeTitle: "Monitor Job")
  private static let researchFamily = SessionFamilyInfo(
    id: "research", representativeID: "research", representativeTitle: "Research Lead")

  private static func member(
    _ id: String, _ title: String, _ family: SessionFamilyInfo, updatedAt: Int64,
    attention: SessionAttentionState? = nil
  ) -> SessionSummary {
    FamilyFixture.member(
      id, title, updatedAt: updatedAt, family: family,
      isPinned: family.isPinned && family.representativeID == id, attention: attention)
  }

  /// The sessions, most recent first.
  static var sessions: [SessionSummary] {
    [
      member("rollout", "Release Rollout", rolloutFamily, updatedAt: 990),
      member("notes", "Release Notes", rolloutFamily, updatedAt: 980),
      SessionSummary(id: "workers", title: "Provision Workers", updatedAt: 970, isPinned: true),
      SessionSummary(
        id: "deploy", title: "Deployment Check", updatedAt: 960, isPinned: true,
        attention: .needsYou),
      SessionSummary(id: "keys", title: "Key Rotation", updatedAt: 950, isPinned: true),
      member("spokes", "Spoke Tests", spokesFamily, updatedAt: 940),
      member("plan", "Plan Review", spokesFamily, updatedAt: 930, attention: .working),
      member("monitor", "Monitor Job", monitorFamily, updatedAt: 920),
      member("monitor-run", "Monitor Run", monitorFamily, updatedAt: 910),
      SessionSummary(id: "internals", title: "Build Internals", updatedAt: 900),
      SessionSummary(id: "extra", title: "Cache Warmup", updatedAt: 890, attention: .needsYou),
      SessionSummary(id: "tool", title: "Lint Rules", updatedAt: 880),
      SessionSummary(id: "shared", title: "Shared Review", updatedAt: 870),
      member("research", "Research Lead", researchFamily, updatedAt: 860),
      member("helper", "Research Helper", researchFamily, updatedAt: 850),
      member("summary", "Research Summary", researchFamily, updatedAt: 845),
      SessionSummary(id: "loose", title: "Loose Notes", updatedAt: 840),
    ]
  }

  /// The sidebar, a minute after the newest update, with the Monitor Job family collapsed.
  static var state: SidebarViewState {
    var state = SidebarViewState(
      list: SessionListViewState(
        sessions: sessions, attentionCounts: ["deploy": 3, "extra": 2],
        now: Date(timeIntervalSince1970: 1050)))
    state.projects = [project, collapsedProject]
    var info: [String: SessionRowInfo] = [:]
    for (index, session) in sessions.enumerated() {
      info[session.id] = SessionRowInfo(harness: "claude", createdAt: Int64(100 + index))
    }
    info["shared"]?.isShared = true
    info["helper"]?.hasDraft = true
    state.rowInfo = info
    state.collapsedFamilies = [SidebarFamilyScope.project(project.id).key(family: "monitor")]
    return state
  }

  /// The rows at each depth, each a parent and a childless sibling where the level has both.
  static let topLevel = ["rollout", "workers", "deploy", "keys", "shared", "research", "loose"]
  /// The rows directly in the Gateway folder.
  static let inProject = ["spokes", "monitor", "internals"]
  /// Rows nested in a family outside any folder.
  static let nested = ["notes", "helper", "summary"]
  /// A row nested in a family inside the folder.
  static let nestedInProject = ["plan"]
}

/// A sidebar shaped like a real one with several projects: two childless pins; Gateway with an
/// expanded family of two members and a family with one; Docs with one session; Tooling
/// collapsed; Infra with two childless sessions; then Shared and Sessions.
enum SidebarProjectsFixture {
  static let gateway = SessionProject(
    id: "gateway", name: "Gateway",
    sessionIds: ["spokes", "plan", "load", "monitor", "monitor-run"])
  static let docs = SessionProject(id: "docs", name: "Docs", sessionIds: ["guide"])
  static let tooling = SessionProject(id: "tools", name: "Tooling", sessionIds: ["lint"])
  static let infra = SessionProject(id: "infra", name: "Infra", sessionIds: ["rotate", "images"])
  /// The folders open in the fixture: all but Tooling.
  static let expanded = ["gateway", "docs", "infra"]

  private static let spokesFamily = SessionFamilyInfo(
    id: "spokes", representativeID: "spokes", representativeTitle: "Spoke Tests")
  private static let monitorFamily = SessionFamilyInfo(
    id: "monitor", representativeID: "monitor", representativeTitle: "Monitor Job")

  /// The sessions, most recent first.
  static var sessions: [SessionSummary] {
    let member = { (id: String, title: String, family: SessionFamilyInfo, updatedAt: Int64) in
      FamilyFixture.member(id, title, updatedAt: updatedAt, family: family)
    }
    return [
      SessionSummary(id: "rollout", title: "Rollout Plan", updatedAt: 990, isPinned: true),
      SessionSummary(id: "incident", title: "Incident Review", updatedAt: 980, isPinned: true),
      member("spokes", "Spoke Tests", spokesFamily, 970),
      member("plan", "Plan Review", spokesFamily, 960),
      member("load", "Load Check", spokesFamily, 955),
      member("monitor", "Monitor Job", monitorFamily, 950),
      member("monitor-run", "Monitor Run", monitorFamily, 940),
      SessionSummary(id: "guide", title: "Write Guide", updatedAt: 930),
      SessionSummary(id: "lint", title: "Lint Rules", updatedAt: 920),
      SessionSummary(id: "rotate", title: "Rotate Keys", updatedAt: 910),
      SessionSummary(id: "images", title: "Bump Images", updatedAt: 900),
      SessionSummary(id: "shared", title: "Shared Review", updatedAt: 890),
      SessionSummary(id: "loose", title: "Loose Notes", updatedAt: 880),
      SessionSummary(id: "scratch", title: "Scratch Pad", updatedAt: 870),
    ]
  }

  /// The sidebar, a minute after the newest update.
  static var state: SidebarViewState {
    var state = SidebarViewState(
      list: SessionListViewState(sessions: sessions, now: Date(timeIntervalSince1970: 1050)))
    state.projects = [gateway, docs, tooling, infra]
    var info: [String: SessionRowInfo] = [:]
    for (index, session) in sessions.enumerated() {
      info[session.id] = SessionRowInfo(harness: "claude", createdAt: Int64(100 + index))
    }
    info["shared"]?.isShared = true
    state.rowInfo = info
    return state
  }
}
