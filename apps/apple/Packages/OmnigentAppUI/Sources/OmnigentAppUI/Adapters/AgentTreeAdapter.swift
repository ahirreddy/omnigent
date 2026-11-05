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

  /// The panel state.
  static func state(_ tools: SessionToolsStore) -> AgentTreeState {
    AgentTreeState(
      nodes: tools.agentTree?.nodes.map(node) ?? [], currentID: tools.sessionID,
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
/// ``AgentTreeAdapter/refreshInterval`` while shown.
struct AgentTreePanelHost: View {
  let conversation: ConversationStore
  let open: @MainActor (String) -> Void

  var body: some View {
    let tools = conversation.tools
    AgentTreePanel(
      state: AgentTreeAdapter.state(tools),
      actions: AgentTreeActions(
        open: open, refresh: { Task { await tools.loadAgentTree() } })
    )
    .task(id: AgentTreeAdapter.childSignature(conversation)) { await tools.loadAgentTree() }
    .task {
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: AgentTreeAdapter.refreshInterval)
        } catch {
          return  // Cancelled: the tab is no longer shown.
        }
        await tools.loadAgentTree()
      }
    }
  }
}
