import OmnigentStores
import OmnigentUIComponents
import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// Control-Tab's recent-sessions switcher on the Mac (web `RecentSessionsSwitcher`): Control-Tab
/// opens it on the session after the open one, each further Tab moves down (Shift up), and
/// releasing Control opens the selection; Esc, or the window losing focus, cancels.
struct RecentSessionsSwitching: ViewModifier {
  let connection: ConnectionStore
  /// The open session.
  let active: String?
  let open: @MainActor (String) -> Void
  @State private var state: RecentSessionsSwitcherState?
  #if os(macOS)
    @State private var monitor = SwitcherKeyMonitor()
  #endif

  /// The switcher's sessions: the most recently active ones not archived, as the web lists them.
  @MainActor static func rows(_ list: SessionListStore) -> [RecentSessionRow] {
    list.sessionsByID.values
      .map { OmnigentUIComponents.SessionSummary($0) }
      .filter { !$0.isArchived }
      .sorted { $0.updatedAt > $1.updatedAt }
      .prefix(RecentSessionsSwitcherState.limit)
      .map {
        RecentSessionRow(
          id: $0.id, title: $0.title, agent: $0.agentName.isEmpty ? "Other" : $0.agentName)
      }
  }

  func body(content: Content) -> some View {
    #if os(macOS)
      content
        .focusedSceneValue(\.recentSessions, RecentSessionsAction { step($0) })
        .overlay(alignment: .top) {
          if let state {
            GeometryReader { geometry in
              RecentSessionsSwitcherView(
                state: state, select: { self.state?.selected = $0 }, commit: commit
              )
              .padding(.horizontal, 24)
              .frame(maxWidth: .infinity)
              .padding(.top, geometry.size.height / 4)
            }
          }
        }
        .onChange(of: state != nil) { _, isOpen in
          guard isOpen else { return monitor.stop() }
          monitor.start(handle)
          // Control may be up already after a quick Control-Tab.
          if !NSEvent.modifierFlags.contains(.control) { commit() }
        }
        .onReceive(Self.windowResigned) { _ in state = nil }
        .onDisappear { monitor.stop() }
    #else
      content
    #endif
  }

  private func step(_ offset: Int) {
    if state == nil {
      state = RecentSessionsSwitcherState(
        rows: Self.rows(connection.sessionList), active: active, offset: offset)
    } else {
      state?.step(by: offset)
    }
  }

  private func commit() {
    let target = state?.selectedID
    state = nil
    if let target, target != active { open(target) }
  }

  #if os(macOS)
    /// A window losing focus cancels the switcher.
    private static var windowResigned: NotificationCenter.Publisher {
      NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
    }

    /// While the switcher shows: Control's release opens the selection, Tab and the arrows move
    /// it, Return opens it and Esc cancels.
    private func handle(_ event: NSEvent) -> Bool {
      if event.type == .flagsChanged {
        if !event.modifierFlags.contains(.control) { commit() }
        return false
      }
      switch event.keyCode {
      case 48: step(event.modifierFlags.contains(.shift) ? -1 : 1)
      case 125: step(1)
      case 126: step(-1)
      case 36, 76: commit()
      case 53: state = nil
      default: return false
      }
      return true
    }
  #endif
}

#if os(macOS)
  /// The key monitor the switcher holds while it shows.
  @MainActor final class SwitcherKeyMonitor {
    private var token: Any?

    /// Watches key presses and Control; `handle` returns whether it took the event.
    func start(_ handle: @escaping @MainActor (NSEvent) -> Bool) {
      stop()
      token = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
        MainActor.assumeIsolated { handle(event) } ? nil : event
      }
    }

    /// Stops watching.
    func stop() {
      if let token { NSEvent.removeMonitor(token) }
      token = nil
    }
  }
#endif
