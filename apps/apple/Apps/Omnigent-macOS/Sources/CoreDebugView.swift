import Foundation
import OmnigentCoreFFI
import OmnigentStores
import SwiftUI

/// Shows or hides the key window's core inspector.
struct CoreDebugToggle {
  let toggle: () -> Void
}

extension FocusedValues {
  /// The key server window's core inspector toggle.
  @Entry var coreDebug: CoreDebugToggle?
}

/// Debug > Show Core Inspector (Option-Shift-Command-D). The menu exists in Debug builds, and in
/// any build launched with `-OmnigentDebugMenu YES`.
struct DebugCommands: Commands {
  @FocusedValue(\.coreDebug) private var coreDebug

  static var isEnabled: Bool {
    #if DEBUG
      isEnabled(isDebugBuild: true, defaults: .standard)
    #else
      isEnabled(isDebugBuild: false, defaults: .standard)
    #endif
  }

  /// Whether the Debug menu shows.
  /// - Parameters:
  ///   - isDebugBuild: Whether this is a Debug build.
  ///   - defaults: Where `-OmnigentDebugMenu YES` lands.
  /// - Returns: `true` in a Debug build, and elsewhere only when the launch asked.
  static func isEnabled(isDebugBuild: Bool, defaults: UserDefaults) -> Bool {
    isDebugBuild || defaults.bool(forKey: "OmnigentDebugMenu")
  }

  var body: some Commands {
    CommandMenu("Debug") {
      Button("Show Core Inspector") { coreDebug?.toggle() }
        .keyboardShortcut("d", modifiers: [.command, .option, .shift])
        .disabled(coreDebug == nil)
    }
  }
}

/// A plain view of what the Rust core reports: the connection phase, the session list and the
/// rows of the selected conversation. A diagnostic, reachable only from the Debug menu.
struct CoreDebugView: View {
  @Environment(ConnectionStore.self) private var store
  @State private var selection: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      status
      Divider()
      sessionList.frame(height: 180)
      Divider()
      transcript
    }
    .task {
      // `-OmnigentCoreDebugSession <id>` preselects a session, for scripted checks.
      if let id = UserDefaults.standard.string(forKey: "OmnigentCoreDebugSession") {
        selection = id
      }
    }
    .onChange(of: selection) { previous, current in
      if let previous { store.closeConversation(previous) }
      if let current { _ = store.conversation(current) }
      store.setView(sessionID: current, focused: true)
    }
  }

  private var status: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Core: \(Self.describe(store.phase))")
        .font(.headline)
        .accessibilityIdentifier("debug.phase")
      Text("Updates socket: \(Self.describe(store.updatesLink))")
        .font(.caption)
        .foregroundStyle(.secondary)
      ForEach(store.issues.suffix(3)) { issue in
        Text(issue.error.message).font(.caption).foregroundStyle(.red)
      }
    }
    .padding(8)
  }

  private var sessionList: some View {
    List(store.sessionList.visible, id: \.id, selection: $selection) { session in
      VStack(alignment: .leading, spacing: 2) {
        Text(session.title).lineLimit(1)
        Text(verbatim: "\(session.status) - \(session.agentName)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .tag(session.id)
      .accessibilityIdentifier("debug.session.\(session.id)")
    }
    .overlay {
      if !store.sessionList.isLoaded {
        ProgressView("Loading sessions")
      } else if store.sessionList.visible.isEmpty {
        Text("No sessions").foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("debug.sessions")
  }

  @ViewBuilder private var transcript: some View {
    if let selection, let conversation = store.conversations[selection] {
      ConversationDebugView(conversation: conversation)
    } else {
      Text("Select a session").foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  static func describe(_ phase: ConnectionPhase) -> String {
    switch phase {
    case .disconnected: "disconnected"
    case .discovering(let url): "discovering \(url)"
    case .signInRequired(let url, _, _, let methods, _): "sign-in required at \(url) (\(methods))"
    case .signingIn(let url): "signing in to \(url)"
    case .awaitingBrowserLogin(let url, _): "waiting for browser sign-in at \(url)"
    case .connecting(let url): "connecting to \(url)"
    case .connected(let server): "connected to \(server.baseUrl) as \(server.userId)"
    case .failed(let url, let error): "failed \(url): \(error.message)"
    }
  }

  static func describe(_ state: LinkState) -> String {
    switch state {
    case .idle: "idle"
    case .connecting: "connecting"
    case .live: "live"
    case .reconnecting(let reason, let failures, let delay):
      "reconnecting in \(delay) ms after \(failures) failures: \(reason.message)"
    case .closed: "closed"
    case .stopped: "stopped"
    case .failed(let error): "failed: \(error.message)"
    }
  }
}

/// The rows of one conversation, as the core published them.
private struct ConversationDebugView: View {
  let conversation: ConversationStore

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        Text(conversation.header?.title ?? conversation.sessionID).font(.headline)
        Text(
          "stream \(CoreDebugView.describe(conversation.link)), "
            + "status \(conversation.header.map { "\($0.status)" } ?? "unknown"), "
            + "\(conversation.rows.count) rows, revision \(conversation.revision)"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("debug.conversation.status")
        ForEach(Array(conversation.errors.suffix(3).enumerated()), id: \.offset) { _, error in
          Text(error.message).font(.caption).foregroundStyle(.red)
        }
      }
      .padding(8)
      Divider()
      List(conversation.rows, id: \.id) { row in
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(verbatim: "\(row.role)").font(.caption.bold())
            if let activity = row.activity {
              Text(verbatim: "\(activity.kind): \(activity.title)").font(.caption)
            }
            if row.isStreaming {
              Text("streaming").font(.caption).foregroundStyle(.orange)
            }
          }
          Text(row.text).textSelection(.enabled).lineLimit(8)
        }
        .accessibilityIdentifier("debug.row.\(row.id)")
      }
      .accessibilityIdentifier("debug.rows")
    }
  }
}
