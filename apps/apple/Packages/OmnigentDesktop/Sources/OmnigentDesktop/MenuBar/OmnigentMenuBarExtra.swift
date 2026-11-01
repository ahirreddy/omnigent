import AppKit
public import SwiftUI

/// The Omnigent menu bar extra: local server and host status with start and stop, sessions
/// that need attention, and quick actions. Settings > Local Server > Show Omnigent in the menu
/// bar inserts or removes it.
///
/// ```swift
/// OmnigentMenuBarExtra(desktop: desktop, sessions: sessionSource)
/// ```
public struct OmnigentMenuBarExtra: Scene {
  private let desktop: DesktopController
  private let sessions: (any MenuBarSessionSource)?

  /// Creates the scene.
  /// - Parameters:
  ///   - desktop: The shell services.
  ///   - sessions: Sessions that need attention; `nil` hides that section.
  public init(desktop: DesktopController, sessions: (any MenuBarSessionSource)? = nil) {
    self.desktop = desktop
    self.sessions = sessions
  }

  /// The extra.
  public var body: some Scene {
    let preferences = desktop.localServerPreferences
    MenuBarExtra(
      isInserted: Binding(
        get: { preferences.showsMenuBarExtra }, set: { preferences.showsMenuBarExtra = $0 })
    ) {
      OmnigentMenuBarContent(desktop: desktop, sessions: sessions)
    } label: {
      OmnigentMenuBarLabel(manager: desktop.localServer, unreadCount: sessions?.unreadCount ?? 0)
    }
    .menuBarExtraStyle(.window)
  }
}

/// The icon in the menu bar, with the unread count when there is one.
struct OmnigentMenuBarLabel: View {
  let manager: LocalServerManager
  let unreadCount: Int

  var body: some View {
    let symbol =
      manager.server.endpoint == nil ? "circle.hexagongrid" : "circle.hexagongrid.fill"
    if unreadCount > 0 {
      Label("Omnigent, \(unreadCount) need you", systemImage: symbol)
        .labelStyle(.titleAndIcon)
        .accessibilityLabel("Omnigent, \(unreadCount) need you")
    } else {
      Image(systemName: symbol).accessibilityLabel("Omnigent")
    }
  }
}

/// The menu bar extra's panel. Public so the app can preview or embed it.
public struct OmnigentMenuBarContent: View {
  private let desktop: DesktopController
  private let sessions: (any MenuBarSessionSource)?
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  /// Creates the panel.
  /// - Parameters:
  ///   - desktop: The shell services.
  ///   - sessions: Sessions that need attention.
  public init(desktop: DesktopController, sessions: (any MenuBarSessionSource)?) {
    self.desktop = desktop
    self.sessions = sessions
  }

  private var manager: LocalServerManager { desktop.localServer }

  /// The panel.
  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      services
      if let sessions {
        Divider()
        AttentionList(sessions: sessions) { session in
          activate()
          desktop.router.open(.conversation(sessionID: session.id), onServer: session.serverURL)
        }
      }
      Divider()
      actions
    }
    .padding(14)
    .frame(width: 340)
    .onAppear {
      // Lets routes from this panel open windows even when every window is closed.
      let openWindow = openWindow
      desktop.router.attachWindowOpener { openWindow(value: $0) }
    }
  }

  private var header: some View {
    HStack {
      Text("Omnigent").font(.title3.weight(.semibold))
      Spacer()
      if let unread = sessions?.unreadCount, unread > 0 {
        Text("\(unread) need you")
          .font(.caption.weight(.medium))
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(.tint.opacity(0.15), in: Capsule())
      }
    }
  }

  @ViewBuilder private var services: some View {
    if case .unavailable(let reason) = manager.capability {
      Text(reason.explanation)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      LocalServiceRow(
        title: "Local Server", tone: manager.server.tone, summary: manager.server.summary,
        startTitle: "Start", canStart: manager.server.canStart,
        canStop: manager.server.canStop, start: { LocalServerActions.startServer(manager) },
        stop: { LocalServerActions.stopServer(manager) })
      LocalServiceRow(
        title: "Host on This Mac", tone: manager.host.tone, summary: manager.host.summary,
        startTitle: "Start\u{2026}",
        canStart: manager.host.canStart && hostTarget != nil, canStop: manager.host.canStop,
        start: { LocalServerActions.startHost(manager, fallback: hostTarget) },
        stop: { LocalServerActions.stopHost(manager) })
    }
  }

  private var actions: some View {
    VStack(alignment: .leading, spacing: 2) {
      MenuRowButton("New Session", systemImage: "square.and.pencil") { newSession() }
      MenuRowButton("Open Omnigent", systemImage: "macwindow") { openOmnigent() }
      if manager.capability.isAvailable {
        MenuRowButton("Show Server Logs", systemImage: "text.alignleft") {
          activate()
          openWindow(id: LocalServerLogsWindow.id)
        }
      }
      MenuRowButton("Settings\u{2026}", systemImage: "gearshape") {
        activate()
        openSettings()
      }
      Divider().padding(.vertical, 4)
      MenuRowButton("Quit Omnigent", systemImage: "power") {
        NSApplication.shared.terminate(nil)
      }
    }
  }

  /// The server to host for: the local server, else the default server.
  private var hostTarget: URL? {
    manager.server.endpoint?.url ?? desktop.preferences.defaultServerURL
  }

  private func newSession() {
    activate()
    guard let server = manager.server.endpoint?.url ?? desktop.preferences.defaultServerURL
    else {
      openWindow(value: ServerWindowID.newWindow(serverURL: nil))
      return
    }
    desktop.router.open(.home, onServer: server)
  }

  private func openOmnigent() {
    activate()
    let windows = NSApplication.shared.windows.filter { $0.canBecomeMain && $0.isVisible }
    if let window = windows.first {
      window.makeKeyAndOrderFront(nil)
    } else {
      openWindow(value: ServerWindowID.newWindow(serverURL: desktop.preferences.defaultServerURL))
    }
  }

  private func activate() {
    NSApplication.shared.activate()
  }
}

/// Sessions that need the user, or a quiet line when there are none.
struct AttentionList: View {
  let sessions: any MenuBarSessionSource
  let open: (AttentionSession) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Needs Attention").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      let rows = sessions.sessionsNeedingAttention.prefix(6)
      if rows.isEmpty {
        Text("Nothing needs you right now.").font(.callout).foregroundStyle(.secondary)
      }
      ForEach(Array(rows)) { session in
        Button {
          open(session)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: symbol(session.reason))
              .foregroundStyle(tint(session.reason))
              .frame(width: 16)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
              Text(session.title).lineLimit(1)
              Text(detail(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(detail(session))
      }
    }
  }

  private func symbol(_ reason: AttentionSession.Reason) -> String {
    switch reason {
    case .awaitingInput: "questionmark.bubble.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .unread: "circle.fill"
    }
  }

  private func tint(_ reason: AttentionSession.Reason) -> Color {
    switch reason {
    case .awaitingInput: .orange
    case .failed: .red
    case .unread: .accentColor
    }
  }

  private func detail(_ session: AttentionSession) -> String {
    let reason =
      switch session.reason {
      case .awaitingInput: "Waiting for your answer"
      case .failed: "Turn failed"
      case .unread(let count): count == 1 ? "1 unread" : "\(count) unread"
      }
    let server = session.serverURL.host(percentEncoded: false) ?? session.serverURL.absoluteString
    let age = session.updatedAt.formatted(.relative(presentation: .named))
    return "\(reason) \u{00B7} \(server) \u{00B7} \(age)"
  }
}

/// A full-width, menu-like row button.
struct MenuRowButton: View {
  let title: String
  let systemImage: String
  let action: () -> Void
  @State private var isHovered = false

  init(_ title: String, systemImage: String, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
          isHovered ? Color.accentColor.opacity(0.18) : .clear,
          in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}
