#if os(macOS)
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Grouped forms and plain stacks build every row, so these take many seconds. They stay as
  /// reproductions, disabled until those lists are lazy.
  @Suite("Long lists in forms", .serialized)
  struct FormRowScaleRenderTests {
    private static var actions: ServerSettingsActions {
      var actions = ServerSettingsActions()
      actions.removeMember = { _ in }
      actions.resetPassword = { _ in nil }
      actions.setPolicyEnabled = { _, _ in }
      actions.deletePolicy = { _ in }
      actions.unarchive = { _ in }
      actions.delete = { _ in }
      return actions
    }

    private func renderNormalWidth(_ view: some View) throws {
      let rendered = try RenderSupport.render(
        view, width: ScreenRenderer.normalWidth, height: 600, scheme: .light, layout: .regular)
      #expect(RenderSupport.inkCoverage(rendered) > 0)
    }

    @Test(
      "400 members, with no hostile text",
      .disabled("About 8 s on the main thread: the form builds each row, about 18 ms a row"))
    func members() throws {
      try renderNormalWidth(
        GroupedFormHost {
          MembersPane(
            members: (0..<400).map {
              ServerMember(id: "user\($0)@example.com", isAdmin: false, canRemove: true)
            }, actions: Self.actions)
        })
    }

    @Test(
      "400 policies, with no hostile text",
      .disabled("About 23 s on the main thread: the form builds each row, about 55 ms a row"))
    func policies() throws {
      try renderNormalWidth(
        GroupedFormHost {
          PoliciesPane(
            policies: (0..<400).map { ServerSettingRow(id: "\($0)", name: "Policy \($0)") },
            actions: Self.actions)
        })
    }

    @Test(
      "800 archived sessions, with no hostile text",
      .disabled("About 5 s on the main thread; a server's archive only grows"))
    func archived() throws {
      try renderNormalWidth(
        GroupedFormHost {
          ArchivedSessionsPane(
            sessions: (0..<800).map { SessionSummary(id: "\($0)", title: "Session \($0)") },
            info: [:], projects: [], hasMore: true, actions: Self.actions)
        })
    }

    @Test(
      "300 chosen GitHub repositories",
      .disabled("About 6 s: each row builds its own branch menu; the repositories aren't lazy"))
    func repositories() throws {
      let github = (0..<300).map {
        GithubRepoOption(
          fullName: "acme/\($0)", cloneURL: "\($0)", defaultBranch: "main", isPrivate: false)
      }
      try renderNormalWidth(
        ScrollView {
          SandboxRepositoriesEditor(
            state: SandboxRepositoriesState(
              repos: (0..<300).map { SandboxRepoChoice(url: "\($0)") }, maxRepos: 1,
              githubRepos: github),
            actions: SandboxRepositoriesActions(
              setRepos: { _ in }, urlProblem: { _, _ in nil }, branchProblem: { _, _ in nil },
              repoName: { $0 }, isSameRepo: { $0 == $1 }))
        })
    }
  }

  /// Data outside what the app writes or a server should send, which used to trap.
  @Suite("Hostile data that crashed")
  struct HostileDataCrashReproductionTests {
    @Test("a huge stored retention is ignored or clamped")
    func retentionOverflow() {
      let days = ArchivedRetention.days("99999999999999999")
      let session = SessionSummary(id: "s", title: "s")
      #expect(
        ArchivedRetention.expired([session], info: [:], days: days, now: .distantPast).isEmpty)
    }

    @Test("a node listed under itself doesn't recurse forever")
    func repeatedNode() {
      let nodes = [
        AgentTreeNode(id: "root", name: "root"),
        AgentTreeNode(id: "a", parentID: "root", depth: 1, name: "a"),
        AgentTreeNode(id: "a", parentID: "a", depth: 2, name: "a"),
      ]
      let centers = AgentTreeLayout.layout(nodes).centers
      #expect(Set(centers.keys) == ["root", "a"])
    }

    @Test("two nodes that name each other as parents leave the tree without them")
    func parentsInACycle() {
      let nodes = [
        AgentTreeNode(id: "root", name: "root"),
        AgentTreeNode(id: "a", parentID: "b", depth: 1, name: "a"),
        AgentTreeNode(id: "b", parentID: "a", depth: 1, name: "b"),
      ]
      #expect(Set(AgentTreeLayout.layout(nodes).centers.keys) == ["root"])
    }

    @Test("the smallest 64-bit expiry reads as expired")
    func countdownBeforeInt() {
      let expired = Date(timeIntervalSince1970: TimeInterval(Int64.min))
      #expect(HarnessDeviceCodeSection.countdown(until: expired, now: .now) == "0:00")
    }

    @Test("an expiry too far ahead for an Int still reads as a time")
    func countdownPastInt() {
      let distant = Date(timeIntervalSinceReferenceDate: 1e300)
      #expect(HarnessDeviceCodeSection.countdown(until: distant, now: .now).contains(":"))
    }
  }
#endif
