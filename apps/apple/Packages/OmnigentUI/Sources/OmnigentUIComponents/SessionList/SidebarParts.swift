import SwiftUI

/// The sidebar header: the Omnigent wordmark (which starts a new session, as the web's brand
/// link), the server switcher, and the web's Search and Settings buttons.
struct SidebarHeader: View {
  let state: SidebarViewState
  let actions: SidebarActions
  @Environment(\.openCommandPalette) private var openPalette
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      wordmark.layoutPriority(1)
      Spacer(minLength: 4)
      if !state.servers.isEmpty || actions.addServer != nil {
        ServerSwitcherMenu(state: state, actions: actions)
      }
      HStack(spacing: Theme.Spacing.tiny) {
        if let openPalette {
          Button("Search", systemImage: "magnifyingglass") { openPalette() }
            .help("Search (\u{2318}K)")
            .accessibilityIdentifier("sidebar-search")
        }
        #if os(macOS)
          Button("Settings", systemImage: "gearshape") { openSettings() }
            .help("Settings (\u{2318},)")
            .accessibilityIdentifier("sidebar-settings")
        #endif
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, Theme.Spacing.large)
    .padding(.vertical, Theme.Spacing.small)
  }

  @ViewBuilder private var wordmark: some View {
    let text = Text("Omnigent").font(.headline.weight(.semibold))
    if let newSession = actions.sessions.newSession {
      Button(action: newSession) { text }
        .buttonStyle(.plain)
        .help("New session")
        .accessibilityLabel("Omnigent, new session")
        .accessibilityIdentifier("sidebar-brand")
    } else {
      text.accessibilityAddTraits(.isHeader)
    }
  }
}

/// The server switcher, as the web's server picker: the organization's servers, Recents,
/// Connect to new server and Sign out, then the native server and app settings.
private struct ServerSwitcherMenu: View {
  let state: SidebarViewState
  let actions: SidebarActions
  @Environment(\.openAppearanceSettings) private var openAppearance
  @Environment(\.openNotificationSettings) private var openNotificationSettings

  private var serverName: String { state.currentServer?.name ?? "none" }

  var body: some View {
    let organization = state.servers.filter(\.isOrganization)
    let recents = state.servers.filter { !$0.isOrganization }
    Menu {
      if !organization.isEmpty {
        Section("Provided by your organization") { servers(organization) }
      }
      if !recents.isEmpty {
        Section("Recents") { servers(recents) }
      }
      Divider()
      if let addServer = actions.addServer {
        Button("Connect to New Server\u{2026}", systemImage: "plus", action: addServer)
      }
      if let signOut = actions.signOut {
        Button(
          "Sign Out of \(serverName)", systemImage: "rectangle.portrait.and.arrow.right",
          action: signOut
        )
        .accessibilityIdentifier("sidebar-sign-out")
      }
      Divider()
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
          .fill(state.currentServer?.isConnected == false ? ThemeColor.secondary : Theme.success)
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
    .accessibilityValue(state.currentServer?.isConnected == false ? "Disconnected" : "Connected")
    .accessibilityHint("Switches the server, connects another, or opens server settings")
    .accessibilityIdentifier("server-switcher")
  }

  private func servers(_ servers: [ServerChoice]) -> some View {
    ForEach(servers) { server in
      Button {
        actions.switchServer?(server)
      } label: {
        if server.id == state.currentServerID {
          Label(server.name, systemImage: "checkmark")
        } else {
          Text(server.name)
        }
      }
      .disabled(actions.switchServer == nil || server.id == state.currentServerID)
    }
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

/// The web's filter menu: Grouping, Display (which sessions), Ordering, then Show (the row's
/// fields). Shared sessions is offered only on a server with sharing.
struct DisplayMenu: View {
  let options: SessionDisplayOptions
  var showsShared = true
  let set: @MainActor (SessionDisplayOptions) -> Void

  var body: some View {
    Menu {
      Picker("Grouping", selection: binding(\.groupBy)) {
        ForEach(SessionGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      Picker("Display", selection: binding(\.show)) {
        ForEach(SessionShowScope.allCases.filter { showsShared || $0 != .shared }, id: \.self) {
          Text($0.title).tag($0)
        }
      }
      Picker("Ordering", selection: binding(\.sortBy)) {
        ForEach(SessionSort.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      Divider()
      Menu("Show") {
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
      Label("Group, sort, and filter sessions", systemImage: "line.3.horizontal.decrease")
        .labelStyle(.iconOnly)
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .menuIndicator(.hidden)
    .tint(.secondary)
    .fixedSize()
    .help("Group, sort, and filter sessions")
    .accessibilityLabel("Group, sort, and filter sessions")
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
