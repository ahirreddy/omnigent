import Testing

@testable import OmnigentUIComponents

@Suite("Switch Host and Resume on a Machine")
struct HostMoveTests {
  private let hosts = [
    HostMoveTarget(id: "old", name: "Old Mac", isOnline: false),
    HostMoveTarget(id: "here", name: "This Mac", isOnline: true),
    HostMoveTarget(id: "lab", name: "Lab", isOnline: true),
  ]

  @Test("Switch Host offers other online hosts, and the old one once a switch is stranded")
  func switchTargets() {
    let online = hosts.map { HostMoveTarget(id: $0.id, name: $0.name, isOnline: true) }
    let kind = HostMoveKind.switchHost(currentHostID: "old")
    #expect(
      HostMoveRules.targets(online, kind: kind, stranded: false).map(\.id) == ["here", "lab"])
    #expect(
      HostMoveRules.targets(online, kind: kind, stranded: true).map(\.id) == ["old", "here", "lab"])
    #expect(HostMoveRules.targets(hosts, kind: kind, stranded: true).map(\.id) == ["here", "lab"])
    let targets = HostMoveRules.targets(hosts, kind: kind, stranded: false)
    #expect(HostMoveRules.defaultHost(targets, kind: kind) == "here")
  }

  @Test("Resume prefers the session's own host while it is online")
  func resumeDefault() {
    let targets = HostMoveRules.targets(
      hosts, kind: .resume(preferredHostID: nil, workspace: nil), stranded: false)
    #expect(targets.map(\.id) == ["here", "lab"])
    #expect(
      HostMoveRules.defaultHost(targets, kind: .resume(preferredHostID: "lab", workspace: nil))
        == "lab")
    #expect(
      HostMoveRules.defaultHost(targets, kind: .resume(preferredHostID: "old", workspace: nil))
        == "here")
    #expect(HostMoveRules.defaultHost([], kind: .switchHost(currentHostID: nil)) == nil)
  }

  @Test("a typed directory resolves to an absolute path, tilde against the host's home")
  func resolvedWorkspace() {
    #expect(HostMoveRules.resolvedWorkspace(" /work/app/ ", home: nil) == "/work/app")
    #expect(HostMoveRules.resolvedWorkspace("///", home: nil) == "/")
    #expect(HostMoveRules.resolvedWorkspace("~/src", home: "/Users/me/") == "/Users/me/src")
    #expect(HostMoveRules.resolvedWorkspace("~", home: "/Users/me") == "/Users/me")
    #expect(HostMoveRules.resolvedWorkspace("~/src", home: nil) == nil)
    #expect(HostMoveRules.resolvedWorkspace("src", home: "/Users/me") == nil)
    #expect(HostMoveRules.resolvedWorkspace("", home: "/Users/me") == nil)
  }

  @Test("the sign-in card offers the fresh code, and drops a stale one when nothing is pending")
  func signInDisplay() {
    let opened = ErrorSignInActions.display(.opened(code: "ABCD-1234"), previousCode: nil)
    #expect(opened.0 == "ABCD-1234")
    #expect(opened.1 == nil)
    let gone = ErrorSignInActions.display(.notPending, previousCode: "ABCD-1234")
    #expect(gone.0 == nil)
    #expect(gone.1?.hasPrefix("No sign-in is pending") == true)
    let failed = ErrorSignInActions.display(.failed("offline"), previousCode: "ABCD-1234")
    #expect(failed.0 == "ABCD-1234")
    #expect(failed.1 == "Could not reach the host for a fresh link: offline")
  }

  @Test("workspace_missing continues in another directory; other fork codes fork")
  func forkLabels() {
    #expect(
      ErrorRowView.forkLabel(code: "workspace_missing") == "Continue in Another Directory\u{2026}")
    #expect(ErrorRowView.forkLabel(code: "session_agent_missing") == "Fork Session\u{2026}")
    #expect(ErrorRowView.forkLabel(code: "rate_limit_exceeded") == nil)
  }
}
