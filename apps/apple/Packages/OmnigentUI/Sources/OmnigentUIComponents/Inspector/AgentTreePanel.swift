public import SwiftUI

/// The Agents tab over the whole spawn tree (web `SubagentsPanel`): the top-level session, then
/// each sub-agent indented under the agent that started it, as a list or a graph. Choosing an
/// agent opens its chat; the one this chat shows is highlighted.
public struct AgentTreePanel: View {
  private let state: AgentTreeState
  private let actions: AgentTreeActions
  @State private var showsGraph = false
  @State private var collapsed: Set<String> = []

  /// Creates the panel.
  /// - Parameters:
  ///   - state: The tree.
  ///   - actions: Open and refresh.
  public init(state: AgentTreeState, actions: AgentTreeActions) {
    self.state = state
    self.actions = actions
  }

  /// The panel.
  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
  }

  private var header: some View {
    // The panel's heading already names the tab; this row holds its controls.
    HStack(spacing: Theme.Spacing.small) {
      Spacer(minLength: 0)
      if let refresh = actions.refresh {
        Button(action: refresh) {
          Image(systemName: "arrow.clockwise").accessibilityLabel("Refresh agents")
        }
        .buttonStyle(.borderless)
        .help("Refresh")
      }
      Picker("View", selection: $showsGraph) {
        Image(systemName: "list.bullet").accessibilityLabel("List view").tag(false)
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .accessibilityLabel("Graph view").tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .help(showsGraph ? "Graph view" : "List view")
      .accessibilityIdentifier("agents.view-mode")
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.bottom, Theme.Spacing.small)
  }

  @ViewBuilder private var content: some View {
    if state.nodes.isEmpty {
      VStack(spacing: Theme.Spacing.small) {
        if let error = state.errorMessage {
          Text("Couldn't load the agents: \(error)").foregroundStyle(Theme.failure)
        } else {
          ProgressView().controlSize(.small)
        }
      }
      .font(.caption)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding()
    } else if showsGraph {
      AgentTreeGraph(state: state, open: actions.open)
    } else {
      list
    }
  }

  private var list: some View {
    List {
      if let error = state.errorMessage {
        Label("Couldn't refresh: \(error)", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(Theme.failure)
      }
      ForEach(state.visible(collapsed: collapsed)) { node in
        AgentTreeRow(
          node: node, isCurrent: node.id == state.currentID,
          isCollapsed: collapsed.contains(node.id), open: actions.open,
          toggle: { toggle(node.id) })
      }
      if state.nodes.count == 1 {
        Text("Sub-agents this session starts appear here.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .listStyle(.plain)
  }

  private func toggle(_ id: String) {
    if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
  }
}

/// One agent: fold control, status tile, role icon, name, routed model and latest message.
private struct AgentTreeRow: View {
  let node: AgentTreeNode
  let isCurrent: Bool
  let isCollapsed: Bool
  let open: (@MainActor (String) -> Void)?
  let toggle: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.extraSmall) {
      disclosure
      // The chat on screen stays enabled so it reads at full strength; choosing it does nothing.
      Button {
        if !isCurrent { open?(node.id) }
      } label: {
        label
      }
      .buttonStyle(.plain)
      .disabled(open == nil)
      .help(isCurrent ? "This chat" : "Open \(node.name)")
    }
    .padding(.leading, CGFloat(max(node.depth - 1, 0)) * Theme.Spacing.large)
    .padding(.vertical, Theme.Spacing.tiny)
    .listRowBackground(
      isCurrent ? RoundedRectangle(cornerRadius: Theme.Radius.small).fill(.quaternary) : nil
    )
    .opacity(node.isSettled && !isCurrent ? 0.6 : 1)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(node.name), \(node.statusLabel)")
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
    .accessibilityIdentifier(node.depth == 0 ? "agents.main" : "agents.child-\(node.id)")
  }

  @ViewBuilder private var disclosure: some View {
    if node.depth > 0 {
      if node.childCount > 0 {
        Button(action: toggle) {
          Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .font(.caption2.weight(.semibold))
            .frame(width: 14, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(isCollapsed ? "Expand sub-agents" : "Collapse sub-agents")
      } else {
        Color.clear.frame(width: 14, height: 22)
      }
    }
  }

  private var label: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.small) {
      if node.depth > 0 {
        AgentStatusTile(activity: node.activity).help(node.statusHelp)
      }
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        HStack(spacing: Theme.Spacing.extraSmall) {
          Image(systemName: node.role.systemImage)
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .accessibilityHidden(true)
          Text(node.name)
            .font(node.depth == 0 ? .callout.weight(.semibold) : .callout)
            .lineLimit(1)
          if node.depth == 0, node.activity == .working {
            ProgressView().controlSize(.mini)
          }
          Spacer(minLength: 0)
          if let model = node.routedModel {
            Text(model)
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .help("Smart routing picked \(model)")
          }
        }
        if let line = node.preview {
          Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

/// A sub-agent's status as a small tinted tile (web `StatusAvatar`).
struct AgentStatusTile: View {
  let activity: AgentTreeActivity

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.15))
      switch activity {
      case .launching, .working:
        ProgressView().controlSize(.mini)
      default:
        Image(systemName: symbol)
          .font(.caption2.weight(.bold))
          .foregroundStyle(tint)
      }
    }
    .frame(width: 22, height: 22)
    .accessibilityHidden(true)
  }

  private var symbol: String {
    switch activity {
    case .needsYou: "questionmark"
    case .failed: "exclamationmark"
    case .disconnected: "bolt.horizontal"
    case .done: "checkmark"
    case .idle: "pause.fill"
    case .launching, .working, .other: "ellipsis"
    }
  }

  private var tint: ThemeColor {
    switch activity {
    case .needsYou: Theme.attention
    case .failed: Theme.failure
    case .done: Theme.success
    case .launching, .working, .disconnected, .idle, .other: ThemeColor.secondary
    }
  }
}
