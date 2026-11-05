import CoreGraphics
import Testing

@testable import OmnigentUIComponents

@Suite("Agents tab spawn tree")
struct AgentTreeStateTests {
  /// root → a → a1, root → b.
  private let nodes = [
    AgentTreeNode(id: "root", name: "Claude Code", childCount: 2),
    AgentTreeNode(id: "a", parentID: "root", depth: 1, name: "a", childCount: 1),
    AgentTreeNode(id: "a1", parentID: "a", depth: 2, name: "a1"),
    AgentTreeNode(id: "b", parentID: "root", depth: 1, name: "b"),
  ]

  @Test("folding an agent hides everything under it, not its siblings")
  func folding() {
    let state = AgentTreeState(nodes: nodes, currentID: "a1")
    #expect(state.visible(collapsed: []).map(\.id) == ["root", "a", "a1", "b"])
    #expect(state.visible(collapsed: ["a"]).map(\.id) == ["root", "a", "b"])
    #expect(state.visible(collapsed: ["root"]).map(\.id) == ["root"])
  }

  @Test("the graph centers each agent over its sub-agents, a level apart")
  func graphLayout() throws {
    let layout = AgentTreeLayout.layout(nodes)
    let width = AgentTreeLayout.nodeSize.width
    let gap = AgentTreeLayout.horizontalGap
    let level = AgentTreeLayout.nodeSize.height + AgentTreeLayout.verticalGap
    #expect(layout.size.width == width * 2 + gap)
    #expect(layout.size.height == level * 2 + AgentTreeLayout.nodeSize.height)
    let root = try #require(layout.centers["root"])
    let first = try #require(layout.centers["a"])
    let second = try #require(layout.centers["b"])
    let grandchild = try #require(layout.centers["a1"])
    #expect(root.x == (first.x + second.x) / 2)
    #expect(first.y - root.y == level)
    #expect(grandchild.x == first.x)
    #expect(second.x - first.x == width + gap)
    #expect(AgentTreeLayout.layout([]).size == .zero)
  }

  @Test("a failure's help names its first error line")
  func statusHelp() {
    let failed = AgentTreeNode(
      id: "x", name: "x", activity: .failed, statusLabel: "Failed", statusDetail: "boom")
    #expect(failed.statusHelp == "Failed: boom")
    #expect(AgentTreeNode(id: "y", name: "y").statusHelp == "Idle")
  }
}
