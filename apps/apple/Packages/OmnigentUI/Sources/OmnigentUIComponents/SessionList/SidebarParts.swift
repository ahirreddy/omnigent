import SwiftUI

/// The sidebar header: the Omnigent wordmark and the server switcher.
struct SidebarHeader: View {
  let state: SidebarViewState
  let actions: SidebarActions
  @Environment(\.openAppearanceSettings) private var openAppearance
  @Environment(\.openNotificationSettings) private var openNotificationSettings

  private var serverName: String { state.currentServer?.name ?? "none" }

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      Text("Omnigent")
        .font(.headline.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 4)
      if !state.servers.isEmpty || actions.addServer != nil {
        Menu {
          ForEach(state.servers) { server in
            Button {
              actions.switchServer?(server)
            } label: {
              if server.id == state.currentServerID {
                Label(server.name, systemImage: "checkmark")
              } else {
                Text(server.name)
              }
            }
            .disabled(actions.switchServer == nil)
          }
          if let addServer = actions.addServer {
            Divider()
            Button("Connect to Server\u{2026}", systemImage: "plus", action: addServer)
          }
          if let settings = actions.openServerSettings {
            Button("Server Settings\u{2026}", systemImage: "gearshape", action: settings)
          }
          if let openAppearance {
            Button("Appearance\u{2026}", systemImage: "paintpalette") { openAppearance() }
              .accessibilityIdentifier("sidebar-appearance")
          }
          if let openNotificationSettings {
            Button("Notifications\u{2026}", systemImage: "bell.badge") {
              openNotificationSettings()
            }
            .accessibilityIdentifier("sidebar-notifications")
          }
        } label: {
          HStack(spacing: Theme.Spacing.extraSmall) {
            Circle()
              .fill(
                state.currentServer?.isConnected == false
                  ? ThemeColor.secondary : Theme.success
              )
              .frame(width: 6, height: 6)
            Text(state.currentServer?.name ?? "Server")
              .font(.caption)
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: Theme.Control.serverNameWidth)
          }
          .accessibilityElement(children: .combine)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .tint(.secondary)
        .help("Server: \(serverName). Switch server or open its settings")
        .accessibilityLabel("Server: \(serverName)")
        .accessibilityValue(
          state.currentServer?.isConnected == false ? "Disconnected" : "Connected"
        )
        .accessibilityHint("Switches the server, connects another, or opens server settings")
        .accessibilityIdentifier("server-switcher")
      }
    }
    .padding(.horizontal, Theme.Spacing.large)
    .padding(.vertical, Theme.Spacing.small)
  }
}

struct QuickFilterRow: View {
  let filter: SessionFilter
  let isActive: Bool
  let count: Int?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack {
        Label(filter.title, systemImage: filter.systemImage)
          .foregroundStyle(ThemeColor.primary)
          .fontWeight(isActive ? .semibold : .regular)
        Spacer()
        if let count, count > 0 {
          Text("\(count)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(filter == .needsResponse ? Theme.attention : Theme.secondary)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tiny)
            .background(ThemeColor.hover, in: Capsule())
        }
      }
      // Height comes from the list's `defaultMinListRowHeight`, as the navigation rows.
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .sidebarSelection(isActive)
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
    .help(isActive ? "Show all sessions" : "Show only: \(filter.title)")
    .accessibilityHint(isActive ? "Shows all sessions" : "Shows only these sessions")
    .accessibilityIdentifier("quick-filter-\(filter.rawValue)")
  }
}

/// The web's filter and display menu: Show, Group by, Sort by and row details.
struct DisplayMenu: View {
  let options: SessionDisplayOptions
  let set: @MainActor (SessionDisplayOptions) -> Void

  var body: some View {
    Menu {
      Picker("Show", selection: binding(\.show)) {
        ForEach(SessionShowScope.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      Picker("Group by", selection: binding(\.groupBy)) {
        ForEach(SessionGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      Picker("Sort by", selection: binding(\.sortBy)) {
        ForEach(SessionSort.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      Section("Row details") {
        ForEach(SessionRowDetail.allCases, id: \.self) { detail in
          Toggle(
            detail.title,
            isOn: Binding(
              get: { options.details.contains(detail) },
              set: { isOn in
                var copy = options
                if isOn { copy.details.insert(detail) } else { copy.details.remove(detail) }
                set(copy)
              }))
        }
      }
    } label: {
      Label("Filter and display", systemImage: "line.3.horizontal.decrease")
        .labelStyle(.iconOnly)
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.hidden)
    .tint(.secondary)
    .fixedSize()
    .help("Filter and display: what to show, grouping, sorting and row details")
    .accessibilityLabel("Filter and display")
    .accessibilityHint("Chooses which sessions show, how they are grouped and sorted")
    .accessibilityIdentifier("sidebar-display-menu")
  }

  private func binding<Value>(_ keyPath: WritableKeyPath<SessionDisplayOptions, Value>) -> Binding<
    Value
  > {
    Binding(
      get: { options[keyPath: keyPath] },
      set: { value in
        var copy = options
        copy[keyPath: keyPath] = value
        set(copy)
      })
  }
}

struct UndoBar: View {
  let banner: UndoBanner
  let actions: SidebarActions

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      Text(banner.message).font(.callout)
      Spacer(minLength: 4)
      if case .archived = banner.kind, let viewArchived = actions.viewArchived {
        Button("View archived", action: viewArchived).buttonStyle(.borderless)
          .accessibilityIdentifier("undo-view-archived")
      }
      if let undo = actions.undo {
        Button("Undo") { undo(banner) }
          .buttonStyle(.borderless)
          .fontWeight(.semibold)
          .keyboardShortcut("z", modifiers: .command)
          .accessibilityIdentifier("undo-action")
      }
      if let dismiss = actions.dismissUndo {
        Button("Dismiss", systemImage: "xmark", action: dismiss)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help("Dismiss")
          .accessibilityIdentifier("undo-dismiss")
      }
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.small)
    .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    .padding(Theme.Spacing.small)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("undo-banner")
  }
}
