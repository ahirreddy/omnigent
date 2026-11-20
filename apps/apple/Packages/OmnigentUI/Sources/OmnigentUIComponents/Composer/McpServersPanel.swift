import SwiftUI

/// The `/mcp` panel over the composer, where the completions show: the session's MCP servers
/// with their account and live state, a sign-in or Reconnect button where one helps, and a link
/// to the harness settings. It reads the servers while it shows.
struct McpServersPanel: View {
  let state: McpServersPanelState
  let actions: McpServersPanelActions

  /// The rows' tallest height before they scroll.
  private static let maxHeight: CGFloat = 256

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      VStack(alignment: .leading, spacing: 0) {
        Text("MCP servers").font(.callout.weight(.semibold))
        Text("Enabled for this session").font(.caption).foregroundStyle(.secondary)
      }
      .padding(.horizontal, Theme.Spacing.medium)
      EditorHeightLayout(minHeight: 0, maxHeight: Self.maxHeight) {
        ScrollView { rows }.scrollBounceBehavior(.basedOnSize)
      }
      Divider().padding(.horizontal, Theme.Spacing.medium)
      footer.padding(.horizontal, Theme.Spacing.medium)
    }
    .padding(.vertical, Theme.Spacing.small)
    .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    .padding(.horizontal, Theme.Spacing.small)
    .task { await actions.watch?() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("mcp-servers-panel")
  }

  private var rows: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      if state.isLoading {
        note("Loading MCP servers\u{2026}")
      } else if state.rows.isEmpty, state.status == nil, state.failure == nil {
        note("No MCP servers enabled for this session.")
      }
      ForEach(state.rows) { row in
        McpServerRowView(row: row, perform: actions.perform)
      }
      if let failure = state.failure {
        Text(failure).font(.caption).foregroundStyle(.red)
          .padding(.horizontal, Theme.Spacing.medium)
      }
      if let status = state.status { note(status) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, Theme.Spacing.extraSmall)
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, Theme.Spacing.medium)
  }

  @ViewBuilder private var footer: some View {
    if let openSettings = actions.openSettings {
      HStack(spacing: 4) {
        Button("Go to Settings", action: openSettings).mcpPanelLinkStyle()
        Text("to configure MCP servers.").foregroundStyle(.secondary)
      }
      .font(.caption)
    }
  }
}

/// One server: its symbol, name, detail and status lines, and its button.
private struct McpServerRowView: View {
  let row: McpServersPanelState.Row
  let perform: (@MainActor (McpServersPanelState.Action) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
        symbol.frame(width: 16)
        VStack(alignment: .leading, spacing: 1) {
          Text(row.name)
          if let detail = row.detail {
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          if let account = row.account {
            Text(account).font(.caption).foregroundStyle(color(row.accountTone))
          }
          if let live = row.live {
            Text(live).font(.caption).foregroundStyle(color(row.liveTone))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: Theme.Spacing.small)
        if let action = row.action, let perform { button(action, perform: perform) }
      }
      if let error = row.error {
        Text(error).font(.caption).foregroundStyle(.red)
          .padding(.leading, 16 + Theme.Spacing.small)
      }
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("mcp-server-row-\(row.name)")
  }

  @ViewBuilder private var symbol: some View {
    switch row.symbol {
    case .failed: icon("xmark.circle.fill", .red)
    case .connecting: ProgressView().controlSize(.mini)
    case .needsSignIn: icon("exclamationmark.triangle.fill", .orange)
    case .unavailable: icon("exclamationmark.circle", .secondary)
    case .connected: icon("powerplug.fill", .green)
    case .idle: icon("powerplug", .secondary)
    }
  }

  private func icon(_ name: String, _ style: some ShapeStyle) -> some View {
    Image(systemName: name).foregroundStyle(style).accessibilityHidden(true)
  }

  private func color(_ tone: McpServersPanelState.Tone) -> Color {
    switch tone {
    case .secondary: .secondary
    case .warning: .orange
    case .failure: .red
    }
  }

  @ViewBuilder
  private func button(
    _ action: McpServersPanelState.Action,
    perform: @escaping @MainActor (McpServersPanelState.Action) -> Void
  ) -> some View {
    switch action {
    case .signIn:
      Button("Sign in") { perform(action) }.buttonStyle(.bordered).controlSize(.small)
    case .signInFromSettings:
      Button("Sign in from Settings") { perform(action) }.mcpPanelLinkStyle().font(.caption)
    case .reconnect(_, let isReconnecting, let isEnabled):
      Button {
        perform(action)
      } label: {
        HStack(spacing: 4) {
          if isReconnecting { ProgressView().controlSize(.mini) }
          Text(isReconnecting ? "Reconnecting\u{2026}" : "Reconnect")
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(!isEnabled)
    }
  }
}

extension View {
  /// A link-like button: the system link style on the Mac, a plain tinted one on iOS.
  @ViewBuilder fileprivate func mcpPanelLinkStyle() -> some View {
    #if os(macOS)
      buttonStyle(.link)
    #else
      buttonStyle(.borderless)
    #endif
  }
}
