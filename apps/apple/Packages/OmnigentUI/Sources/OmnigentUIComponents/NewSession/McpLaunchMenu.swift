public import SwiftUI

/// Whether the viewer can use an MCP service.
nonisolated public enum McpServiceConnection: Hashable, Sendable {
  /// The viewer's account is connected (or the service needs none).
  case connected
  /// A personal token connects it, in Settings.
  case needsToken
  /// The viewer signs in to it through the browser.
  case needsSignIn
}

/// The MCPs menu's actions.
public struct McpLaunchActions {
  /// Turns a service on or off for the launch.
  public var toggle: @MainActor (String, Bool) -> Void
  /// Reads the services again after a failure.
  public var reload: @MainActor () -> Void

  /// Creates actions.
  /// - Parameters:
  ///   - toggle: Turn a service on or off.
  ///   - reload: Read the services again.
  public init(
    toggle: @escaping @MainActor (String, Bool) -> Void, reload: @escaping @MainActor () -> Void
  ) {
    self.toggle = toggle
    self.reload = reload
  }
}

/// The server-configured MCP services a new session can start with (the web's
/// `McpRegistryLaunchPicker`). Credentials stay on the server.
nonisolated public struct McpLaunchServices: Hashable, Sendable {
  /// One service.
  public struct Service: Hashable, Sendable, Identifiable {
    /// The service id sent at launch.
    public var id: String
    /// Its name.
    public var title: String
    /// One line about it.
    public var description: String?
    /// Whether the viewer can use it.
    public var connection: McpServiceConnection
    /// It goes with the session.
    public var isSelected: Bool

    /// Creates a service.
    /// - Parameters:
    ///   - id: Service id.
    ///   - title: Name.
    ///   - description: About it.
    ///   - connection: Whether the viewer can use it.
    ///   - isSelected: It goes with the session.
    public init(
      id: String, title: String, description: String? = nil, connection: McpServiceConnection,
      isSelected: Bool
    ) {
      self.id = id
      self.title = title
      self.description = description
      self.connection = connection
      self.isSelected = isSelected
    }

    /// The line under its name, in the web's words.
    public var status: String {
      switch connection {
      case .connected: "Connected"
      case .needsToken: "Connect your account in settings"
      case .needsSignIn: "Needs sign-in"
      }
    }

    /// Turning it on is allowed: only a connected service; one already on can always go off.
    public var canToggle: Bool { isSelected || connection == .connected }
  }

  /// Reading the registry.
  public enum Phase: Hashable, Sendable {
    /// Being read.
    case loading
    /// Listed.
    case loaded
    /// It could not be read.
    case failed(String)
  }

  /// The registry read.
  public var phase: Phase
  /// The services, in the server's order.
  public var services: [Service]
  /// How many are selected: the remembered count while the list is unknown.
  public var selectedCount: Int

  /// Creates the state.
  /// - Parameters:
  ///   - phase: The read.
  ///   - services: Services.
  ///   - selectedCount: Selected, as the chip counts them.
  public init(phase: Phase, services: [Service], selectedCount: Int) {
    self.phase = phase
    self.services = services
    self.selectedCount = selectedCount
  }

  /// Selected services the viewer still has to connect.
  public var needsSignInCount: Int {
    services.filter { $0.isSelected && $0.connection != .connected }.count
  }

  /// The chip's text: `MCPs`, or `MCPs · 2`.
  public var chipTitle: String {
    selectedCount > 0 ? "MCPs \u{00B7} \(selectedCount)" : "MCPs"
  }
}

/// The MCPs chip and its menu of services under the new-session composer; nothing where the
/// server has no registry or the page offers no toggles.
struct McpLaunchMenu: View {
  let state: McpLaunchServices?
  let actions: McpLaunchActions?

  var body: some View {
    if let state, let actions {
      menu(state, actions)
    }
  }

  private func menu(_ state: McpLaunchServices, _ actions: McpLaunchActions) -> some View {
    Menu {
      Section {
        Text(
          "Turn on the server-configured MCP services this session should use. Sign in to "
            + "services that need it in Omnigent's MCP settings on the web.")
      } header: {
        Text("Tools for this session")
      }
      switch state.phase {
      case .loading:
        Text("Loading MCP services\u{2026}")
      case .failed(let message):
        Text(message)
        Button("Retry", action: actions.reload)
      case .loaded where state.services.isEmpty:
        Text("No managed services are available for your account.")
      case .loaded:
        ForEach(state.services) { service in
          Toggle(
            isOn: Binding(get: { service.isSelected }, set: { actions.toggle(service.id, $0) })
          ) {
            Text(service.title)
            Text(service.status)
          }
          .disabled(!service.canToggle)
          .help(service.description ?? service.title)
          .accessibilityIdentifier("new-session-mcp-\(service.id)")
        }
      }
    } label: {
      HStack(spacing: Theme.Spacing.extraSmall) {
        Image(systemName: "powerplug")
          .foregroundStyle(state.needsSignInCount > 0 ? Theme.warning : .secondary)
        Text(state.chipTitle)
        if state.needsSignInCount > 0 {
          Text("\u{00B7} \(state.needsSignInCount) needs sign-in").foregroundStyle(Theme.warning)
        }
      }
    }
    .fixedSize()
    .help(
      state.needsSignInCount > 0
        ? "\(state.needsSignInCount) MCP services need sign-in" : "MCP services"
    )
    .accessibilityLabel(Self.accessibilityLabel(state))
    .accessibilityIdentifier("new-session-mcp-services")
  }

  /// The chip's label, as the web's `aria-label`.
  static func accessibilityLabel(_ state: McpLaunchServices) -> String {
    let needs = state.needsSignInCount
    return "MCP services: \(state.selectedCount) selected"
      + (needs > 0 ? ", \(needs) needs sign-in" : "")
  }
}
