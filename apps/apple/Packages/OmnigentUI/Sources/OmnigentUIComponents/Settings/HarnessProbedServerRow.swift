import SwiftUI

/// An MCP server that opens to its tools: its connection status and tool count on the row, and
/// the tools, or why there are none, inside, as the web's `McpRow`. Opening it probes.
struct HarnessProbedServerRow: View {
  let server: HarnessCatalogState.Server
  let probe: @MainActor (String) -> Void

  @State private var expanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      content
    } label: {
      label
    }
    .onChange(of: expanded) { _, open in
      if open { probe(server.id) }
    }
    .accessibilityIdentifier("harness-mcp-\(server.id)")
  }

  private var label: some View {
    HStack(spacing: Theme.Spacing.medium) {
      Image(systemName: "server.rack").foregroundStyle(.secondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: Theme.Spacing.extraSmall) {
          Text(server.title)
          if let count = server.status?.toolCount {
            Text("\u{00B7} \(count)").foregroundStyle(.secondary)
          }
        }
        if let detail = server.detail {
          Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      if let status = server.status {
        Label {
          Text(status.label)
        } icon: {
          Circle().fill(color(status.tone)).frame(width: 8, height: 8)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("harness-mcp-status")
      }
    }
    .contentShape(Rectangle())
  }

  @ViewBuilder private var content: some View {
    switch server.probe {
    case nil, .loading:
      HStack(spacing: Theme.Spacing.small) {
        ProgressView().controlSize(.small)
        Text("Loading tools\u{2026}").foregroundStyle(.secondary)
      }
    case .notice(let text):
      Text(text).foregroundStyle(.secondary)
    case .tools(let tools, let truncated):
      if tools.isEmpty {
        Text("No tools reported.").foregroundStyle(.secondary)
      }
      if truncated {
        Text("Showing the first 500 tools.").foregroundStyle(.secondary)
      }
      ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
        if let description = tool.description {
          DisclosureGroup {
            Text(description).font(.caption).foregroundStyle(.secondary)
              .textSelection(.enabled)
          } label: {
            Text(tool.name).font(.caption.monospaced())
          }
        } else {
          Text(tool.name).font(.caption.monospaced())
        }
      }
    }
  }

  private func color(_ tone: HarnessMcpStatus.Tone) -> ThemeColor {
    switch tone {
    case .connected: Theme.success
    case .attention: Theme.warning
    case .failed: Theme.failure
    }
  }
}
