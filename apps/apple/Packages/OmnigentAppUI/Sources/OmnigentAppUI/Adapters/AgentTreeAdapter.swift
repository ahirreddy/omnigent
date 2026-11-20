import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The Agents tab's spawn tree from the core's read of it.
enum AgentTreeAdapter {
  /// How often the shown tab reads the tree again; sub-agents of other agents report no events
  /// to this chat.
  static let refreshInterval: Duration = .seconds(15)

  /// The panel state, each agent tagged with its cost from `costs`.
  static func state(_ tools: SessionToolsStore, costs: [String: String] = [:]) -> AgentTreeState {
    AgentTreeState(
      nodes: tools.agentTree?.nodes.map { node in
        var mapped = Self.node(node)
        mapped.costLabel = costs[node.sessionId]
        return mapped
      } ?? [], currentID: tools.sessionID,
      isLoading: tools.agentTree == nil && tools.agentTreeError == nil,
      errorMessage: tools.agentTreeError?.message)
  }

  static func node(_ node: AgentNode) -> AgentTreeNode {
    AgentTreeNode(
      id: node.sessionId, parentID: node.parentId, depth: Int(node.depth), name: node.name,
      role: role(node.role), activity: activity(node.activity), statusLabel: node.statusLabel,
      statusDetail: node.statusDetail, isSettled: node.isSettled, preview: node.preview,
      routedModel: node.routedModel, childCount: Int(node.childCount))
  }

  static func activity(_ activity: AgentActivity) -> AgentTreeActivity {
    switch activity {
    case .launching: .launching
    case .working: .working
    case .needsYou: .needsYou
    case .done: .done
    case .failed: .failed
    case .disconnected: .disconnected
    case .idle: .idle
    case .other: .other
    }
  }

  static func role(_ role: AgentRole) -> AgentTreeRole {
    switch role {
    case .explore: .explore
    case .research: .research
    case .plan: .plan
    case .review: .review
    case .test: .test
    case .docs: .docs
    case .code: .code
    case .generic: .generic
    }
  }

  /// The session overview's sub-agent costs (`agent_costs`).
  static func costSource(_ conversation: ConversationStore) -> AgentCostSource {
    AgentCostSource {
      do throws(CoreError) {
        return .success(try await conversation.agentCostTags())
      } catch {
        return .failure(LogReadFailure(message: error.message))
      }
    }
  }

  /// The Agents tab over the conversation's spawn tree.
  static func panel(_ conversation: ConversationStore, open: @escaping @MainActor (String) -> Void)
    -> AnyView
  {
    AnyView(AgentTreePanelHost(conversation: conversation, open: open))
  }

  /// What changes when this chat's own sub-agents start or change state, so the tree is read
  /// again then.
  static func childSignature(_ store: ConversationStore) -> [String] {
    store.sections.filter { $0.id.hasPrefix("child-") }.map { section in
      let state = section.details.first { $0.id == "state" }?.text ?? ""
      return "\(section.id):\(state)"
    }
  }
}

/// The Agents tab: reads the tree when shown, when this chat's sub-agents change and every
/// ``AgentTreeAdapter/refreshInterval`` while shown. With `session_overview` each agent shows
/// its cost, read with the tree (`agent_costs`).
struct AgentTreePanelHost: View {
  let conversation: ConversationStore
  let open: @MainActor (String) -> Void
  var refreshInterval = AgentTreeAdapter.refreshInterval
  @Environment(\.offersSessionOverview) private var showsCosts
  @State private var costs = AgentCostReading()

  var body: some View {
    let tools = conversation.tools
    AgentTreePanel(
      state: AgentTreeAdapter.state(tools, costs: costs.tags),
      actions: AgentTreeActions(
        open: open, refresh: { Task { await load() } })
    )
    .task(id: AgentTreeAdapter.childSignature(conversation)) { await load() }
    .task {
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: refreshInterval)
        } catch {
          return  // Cancelled: the tab is no longer shown.
        }
        await load()
      }
    }
  }

  private func load() async {
    await conversation.tools.loadAgentTree()
    guard showsCosts, costs.isSupported else { return }
    costs = await costs.read(conversation)
  }
}

/// The agents' cost tags, read again while shown; a server without them is asked no more.
struct AgentCostReading {
  private(set) var tags: [String: String] = [:]
  private(set) var isSupported = true
  /// Why the latest read failed; the last tags stay.
  private(set) var failure: String?

  /// These tags read again: the new ones, or the old ones and why the read failed.
  func read(_ conversation: ConversationStore) async -> Self {
    var next = self
    do throws(CoreError) {
      if let read = try await conversation.agentCostTags() {
        next.tags = read
      } else {
        next.isSupported = false
      }
      next.failure = nil
    } catch {
      next.failure = error.message
    }
    return next
  }
}
