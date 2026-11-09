#if os(macOS)
  import Foundation
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Usage and Agents tab with hostile data", .serialized)
  struct UsageAndAgentTreeRenderTests {
    private static var usageActions: UsageActions {
      var actions = UsageActions(formatCost: PreviewData.cost)
      actions.openSession = { _ in }
      actions.retry = {}
      actions.setRange = { _, _, _ in }
      return actions
    }

    private static var hostileAmounts: [UsageAmount] {
      (0..<HostileData.rowCount).map { index in
        UsageAmount(label: "\(HostileData.text(index)) \(index)", costUSD: Double(index) - 100)
      }
    }

    /// Every date a cost report could stretch the daily axis with, and labels that aren't dates.
    private static var hostileDaily: [UsageAmount] {
      [
        UsageAmount(label: "0001-01-01", costUSD: 0),
        UsageAmount(label: "9999-12-31", costUSD: -5),
        UsageAmount(label: "2026-13-45", costUSD: 1e12),
        UsageAmount(label: "2026-00-00", costUSD: 1e-12),
        UsageAmount(label: "not-a-date", costUSD: 1),
        UsageAmount(label: "", costUSD: 1),
      ]
    }

    private static func sessionRows(_ count: Int) -> [UsageSessionRow] {
      (0..<count).map { index in
        UsageSessionRow(
          id: "\(index)", title: HostileData.text(index), model: HostileData.text(index + 1),
          harness: HostileData.text(index + 2), updatedAt: HostileData.date(index),
          costUSD: Double(index) - 2, costText: HostileData.text(index + 3))
      }
    }

    private static var hostileUsage: UsageViewState {
      UsageViewState(
        totalText: HostileData.bidirectional, daily: hostileDaily, byHarness: hostileAmounts,
        byModel: Array(hostileAmounts.prefix(4)), sessions: sessionRows(HostileData.rowCount))
    }

    private static var realisticTree: AgentTreeState {
      AgentTreeState(
        nodes: [
          AgentTreeNode(id: "root", name: "Claude Code", activity: .working, childCount: 2),
          AgentTreeNode(
            id: "a", parentID: "root", depth: 1, name: "explore", role: .explore,
            activity: .working, statusLabel: "Working", preview: "Reading the store",
            routedModel: "claude-sonnet-4", childCount: 1),
          AgentTreeNode(
            id: "a1", parentID: "a", depth: 2, name: "tests", role: .test, activity: .failed,
            statusLabel: "Failed", statusDetail: "Tunnel closed"),
          AgentTreeNode(
            id: "b", parentID: "root", depth: 1, name: "docs", role: .docs, activity: .done,
            statusLabel: "Done", isSettled: true),
        ], currentID: "a1")
    }

    /// A root with a few hundred sub-agents, one chain deep enough to indent off the screen, and
    /// every activity and role with each kind of hostile text.
    private static var hostileTree: AgentTreeState {
      let activities = AgentTreeActivity.allCases
      let roles = AgentTreeRole.allCases
      var nodes = [
        AgentTreeNode(
          id: "root", name: HostileData.unbroken, activity: .working,
          childCount: HostileData.rowCount)
      ]
      nodes += (0..<HostileData.rowCount).map { index in
        AgentTreeNode(
          id: "\(index)", parentID: index % 50 == 49 ? "\(index - 1)" : "root",
          depth: index % 50 == 49 ? 100_000 : 1, name: HostileData.text(index),
          role: roles[index % roles.count], activity: activities[index % activities.count],
          statusLabel: HostileData.text(index + 1), statusDetail: HostileData.text(index + 2),
          isSettled: index.isMultiple(of: 2), preview: HostileData.text(index + 3),
          routedModel: HostileData.text(index), childCount: index.isMultiple(of: 3) ? Int.max : -1)
      }
      return AgentTreeState(
        nodes: nodes, currentID: "missing", errorMessage: HostileData.bidirectional)
    }

    nonisolated static let screens: [ScreenCase] = [
      ScreenCase("usage-realistic", realistic: true) {
        UsageView(state: PreviewData.usage, actions: usageActions)
      },
      ScreenCase("usage-empty", realistic: true, narrowOnly: true) {
        UsageView(state: UsageViewState(), actions: usageActions)
      },
      ScreenCase("usage-loading", narrowOnly: true) {
        UsageView(state: UsageViewState(isLoading: true), actions: usageActions)
      },
      ScreenCase("usage-load-error", narrowOnly: true) {
        UsageView(state: UsageViewState(loadError: HostileData.unbroken), actions: usageActions)
      },
      ScreenCase("usage-hostile") {
        UsageView(state: hostileUsage, actions: usageActions)
      },
      ScreenCase("usage-long-total", narrowOnly: true) {
        UsageView(state: UsageViewState(totalText: HostileData.unbroken), actions: usageActions)
      },
      ScreenCase("usage-zero-and-negative-only", narrowOnly: true) {
        let amounts = [
          UsageAmount(label: "zero", costUSD: 0), UsageAmount(label: "negative", costUSD: -1),
        ]
        return UsageView(
          state: UsageViewState(
            totalText: "-$1.00",
            daily: [
              UsageAmount(label: "2026-10-18", costUSD: 0),
              UsageAmount(label: "2026-10-18", costUSD: -1),
            ], byHarness: amounts, byModel: amounts, sessions: sessionRows(2)),
          actions: usageActions)
      },
      ScreenCase("agent-tree-realistic", realistic: true) {
        AgentTreePanel(state: realisticTree, actions: AgentTreeActions(open: { _ in }, refresh: {}))
      },
      ScreenCase("agent-tree-empty", realistic: true, narrowOnly: true) {
        AgentTreePanel(
          state: AgentTreeState(nodes: [], currentID: "", isLoading: true),
          actions: AgentTreeActions())
      },
      ScreenCase("agent-tree-empty-error", narrowOnly: true) {
        AgentTreePanel(
          state: AgentTreeState(nodes: [], currentID: "", errorMessage: HostileData.unbroken),
          actions: AgentTreeActions())
      },
      ScreenCase("agent-tree-only-root", narrowOnly: true) {
        AgentTreePanel(
          state: AgentTreeState(nodes: [AgentTreeNode(id: "r", name: "")], currentID: "r"),
          actions: AgentTreeActions())
      },
      ScreenCase("agent-tree-hostile") {
        AgentTreePanel(state: hostileTree, actions: AgentTreeActions(open: { _ in }, refresh: {}))
      },
      ScreenCase("agent-graph-realistic", realistic: true, narrowOnly: true) {
        AgentTreeGraph(state: realisticTree, open: { _ in })
      },
      ScreenCase("agent-graph-hostile", narrowOnly: true) {
        AgentTreeGraph(state: hostileTree, open: { _ in })
      },
    ]

    @Test("renders without crashing or hanging", arguments: screens)
    func render(screen: ScreenCase) throws {
      try ScreenRenderer.check(screen)
    }
  }

  @Suite("Usage state rules")
  struct UsageStateRulesTests {
    private var calendar: Calendar {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
      return calendar
    }

    @Test("a daily label is that calendar day, whatever the time zone")
    func dayFromLabel() throws {
      let day = try #require(UsageAmount(label: "2026-10-18", costUSD: 0).day(in: calendar))
      let parts = calendar.dateComponents([.year, .month, .day, .hour], from: day)
      #expect(parts.year == 2_026 && parts.month == 10 && parts.day == 18 && parts.hour == 0)
    }

    @Test(
      "a label that isn't YYYY-MM-DD has no day",
      arguments: [
        "", "claude-code", "2026-10", "2026-10-180", "2026/10/18", "abcd-ef-gh", "2026-10-1",
      ])
    func labelsWithoutDay(label: String) {
      #expect(UsageAmount(label: label, costUSD: 0).day(in: calendar) == nil)
    }

    @Test(
      "a date that doesn't exist has no day, instead of rolling over",
      arguments: ["2026-13-45", "2026-00-00", "9999-99-99", "-123-45-67", "99999-1-01"])
    func impossibleDates(label: String) {
      #expect(UsageAmount(label: label, costUSD: 0).day(in: calendar) == nil)
    }

    @Test("the presets span their days; all time and custom have none")
    func rangeDays() {
      #expect(UsageRange.allCases.map(\.days) == [7, 30, 90, nil, nil])
      #expect(Set(UsageRange.allCases.map(\.title)).count == UsageRange.allCases.count)
    }
  }

  @Suite("Agents graph layout with hostile trees")
  struct AgentTreeHostileLayoutTests {
    @Test("a few hundred siblings spread out; the bounds hold every node")
    func wideTree() throws {
      var nodes = [AgentTreeNode(id: "root", name: "root", childCount: HostileData.rowCount)]
      nodes += (0..<HostileData.rowCount).map {
        AgentTreeNode(id: "\($0)", parentID: "root", depth: 1, name: "\($0)")
      }
      let layout = AgentTreeLayout.layout(nodes)
      #expect(layout.centers.count == nodes.count)
      let width = AgentTreeLayout.nodeSize.width
      let gap = AgentTreeLayout.horizontalGap
      let count = CGFloat(HostileData.rowCount)
      #expect(layout.size.width == count * width + (count - 1) * gap)
      for center in layout.centers.values {
        #expect(center.x >= width / 2 && center.x <= layout.size.width - width / 2)
      }
    }

    @Test("a chain a few hundred deep lays out")
    func deepTree() {
      var nodes = [AgentTreeNode(id: "0", name: "root")]
      nodes += (1...HostileData.rowCount).map {
        AgentTreeNode(id: "\($0)", parentID: "\($0 - 1)", depth: $0, name: "\($0)")
      }
      let layout = AgentTreeLayout.layout(nodes)
      #expect(layout.centers.count == nodes.count)
      #expect(layout.size.width == AgentTreeLayout.nodeSize.width)
    }

    @Test("an orphan is left out of the graph and shown in the list")
    func orphan() {
      let nodes = [
        AgentTreeNode(id: "root", name: "root"),
        AgentTreeNode(id: "orphan", parentID: "gone", depth: 1, name: "orphan"),
      ]
      #expect(AgentTreeLayout.layout(nodes).centers["orphan"] == nil)
      let state = AgentTreeState(nodes: nodes, currentID: "root")
      #expect(state.visible(collapsed: []).map(\.id) == ["root", "orphan"])
    }

    @Test("folding an unknown agent, or the current one, changes nothing else")
    func foldingUnknown() {
      let nodes = [
        AgentTreeNode(id: "root", name: "root"),
        AgentTreeNode(id: "a", parentID: "root", depth: 1, name: "a"),
      ]
      let state = AgentTreeState(nodes: nodes, currentID: "a")
      #expect(state.visible(collapsed: ["unknown"]).map(\.id) == ["root", "a"])
      #expect(AgentTreeState(nodes: [], currentID: "").visible(collapsed: ["a"]).isEmpty)
    }
  }
#endif
