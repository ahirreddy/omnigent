import AppKit
public import SwiftUI

/// A colored dot for a process state.
struct LocalStatusDot: View {
  enum Tone {
    case off, busy, good, bad
  }

  let tone: Tone

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 8, height: 8)
      .accessibilityHidden(true)
  }

  private var color: Color {
    switch tone {
    case .off: .secondary.opacity(0.5)
    case .busy: .orange
    case .good: .green
    case .bad: .red
    }
  }
}

extension LocalServerStatus {
  var tone: LocalStatusDot.Tone {
    switch self {
    case .unavailable, .stopped: .off
    case .checking, .starting, .stopping: .busy
    case .running: .good
    case .crashed, .failed: .bad
    }
  }
}

extension LocalHostStatus {
  var tone: LocalStatusDot.Tone {
    switch self {
    case .unavailable, .stopped: .off
    case .awaitingConfirmation, .connecting, .stopping: .busy
    case .connected: .good
    case .crashed, .failed: .bad
    }
  }
}

/// Actions shared by the Server menu, Settings and the menu bar extra.
@MainActor
enum LocalServerActions {
  static func startServer(_ manager: LocalServerManager) {
    Task { await manager.startServer(trigger: .user) }
  }

  static func stopServer(_ manager: LocalServerManager) {
    Task { await manager.stopServer() }
  }

  /// Hosts for the local server when it runs, else for `fallback` (the key window's server).
  static func startHost(_ manager: LocalServerManager, fallback: URL?) {
    let target = manager.server.endpoint?.url ?? fallback
    Task { await manager.startHost(serverURL: target) }
  }

  static func stopHost(_ manager: LocalServerManager) {
    Task { await manager.stopHost() }
  }

  /// Opens the CLI's log folder in Finder, creating nothing.
  static func revealLogFolder(_ manager: LocalServerManager) -> String? {
    let folder = manager.serverLogDirectory
    guard FileManager.default.fileExists(atPath: folder.path) else {
      return "\(folder.path) does not exist yet. The server creates it when it first starts."
    }
    NSWorkspace.shared.activateFileViewerSelecting([folder])
    return nil
  }
}

/// One process row: status dot, title, summary, and a start or stop button.
struct LocalServiceRow: View {
  let title: String
  let tone: LocalStatusDot.Tone
  let summary: String
  let startTitle: String
  let canStart: Bool
  let canStop: Bool
  let start: () -> Void
  let stop: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      LocalStatusDot(tone: tone)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(summary)
          .font(.callout)
          .foregroundStyle(tone == .bad ? .red : .secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      Spacer(minLength: 8)
      if canStop {
        Button("Stop", action: stop)
      } else {
        Button(startTitle, action: start).disabled(!canStart)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
