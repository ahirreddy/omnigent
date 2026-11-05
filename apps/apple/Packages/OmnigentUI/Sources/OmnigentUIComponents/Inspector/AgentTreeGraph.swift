import SwiftUI

/// The spawn tree as a top-down graph (web `SubagentsGraphView`): a card per agent, tinted by
/// where it stands, linked to the agent that started it. Scrolls both ways, with zoom controls.
struct AgentTreeGraph: View {
  let state: AgentTreeState
  let open: (@MainActor (String) -> Void)?
  @State private var zoom: CGFloat = 1
  private static let padding: CGFloat = 24

  var body: some View {
    let layout = AgentTreeLayout.layout(state.nodes)
    let size = CGSize(
      width: layout.size.width + Self.padding * 2, height: layout.size.height + Self.padding * 2)
    ScrollView([.horizontal, .vertical]) {
      ZStack(alignment: .topLeading) {
        edges(layout.centers)
        ForEach(state.nodes) { node in
          if let center = layout.centers[node.id] {
            card(node)
              .position(x: center.x + Self.padding, y: center.y + Self.padding)
          }
        }
      }
      .frame(width: size.width, height: size.height)
      .scaleEffect(zoom, anchor: .topLeading)
      .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
    }
    .overlay(alignment: .bottomTrailing) { zoomControls }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Agents graph")
  }

  private func edges(_ centers: [String: CGPoint]) -> some View {
    let half = AgentTreeLayout.nodeSize.height / 2
    return Canvas { context, _ in
      for node in state.nodes {
        guard let parent = node.parentID, let from = centers[parent], let to = centers[node.id]
        else { continue }
        let start = CGPoint(x: from.x + Self.padding, y: from.y + half + Self.padding)
        let end = CGPoint(x: to.x + Self.padding, y: to.y - half + Self.padding)
        let middle = (start.y + end.y) / 2
        var path = Path()
        path.move(to: start)
        path.addCurve(
          to: end, control1: CGPoint(x: start.x, y: middle), control2: CGPoint(x: end.x, y: middle))
        let opacity = node.activity == .working ? 0.6 : 0.3
        context.stroke(path, with: .color(.secondary.opacity(opacity)), lineWidth: 1.5)
      }
    }
    .accessibilityHidden(true)
  }

  private func card(_ node: AgentTreeNode) -> some View {
    let isCurrent = node.id == state.currentID
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
    return Button {
      if !isCurrent { open?(node.id) }
    } label: {
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        HStack(spacing: Theme.Spacing.extraSmall) {
          Image(systemName: node.role.systemImage).foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text(node.name).font(.callout.weight(.medium)).lineLimit(1)
          Spacer(minLength: 0)
          AgentStatusTile(activity: node.activity).scaleEffect(0.8)
        }
        if let preview = node.preview {
          Text(preview).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        if !node.isSettled {
          Text(node.statusLabel).font(.caption2).foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, Theme.Spacing.small)
      .frame(
        width: AgentTreeLayout.nodeSize.width, height: AgentTreeLayout.nodeSize.height,
        alignment: .leading
      )
      .background(shape.fill(.background))
      .overlay(shape.strokeBorder(border(node.activity), lineWidth: isCurrent ? 2 : 1))
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .disabled(open == nil)
    .help("\(node.name): \(node.statusHelp)")
    .accessibilityLabel("\(node.name), \(node.statusLabel)")
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }

  private func border(_ activity: AgentTreeActivity) -> ThemeColor {
    switch activity {
    case .needsYou: Theme.attention
    case .failed: Theme.failure
    case .working: Theme.running
    case .launching, .done, .disconnected, .idle, .other: ThemeColor.border
    }
  }

  private var zoomControls: some View {
    VStack(spacing: 0) {
      zoomButton("Zoom in", symbol: "plus.magnifyingglass") { zoom = min(zoom * 1.25, 2) }
      zoomButton("Zoom out", symbol: "minus.magnifyingglass") { zoom = max(zoom / 1.25, 0.4) }
      zoomButton("Actual size", symbol: "1.magnifyingglass") { zoom = 1 }
    }
    .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.small), isInteractive: true)
    .padding(Theme.Spacing.small)
  }

  private func zoomButton(_ title: String, symbol: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(title)
    .accessibilityLabel(title)
  }
}
