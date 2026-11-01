import AppKit
public import SwiftUI

/// The Server Logs window: `Window(id: LocalServerLogsWindow.id)`. Open it with
/// `openWindow(id: LocalServerLogsWindow.id)`; Server > Show Server Logs does.
public struct LocalServerLogsWindow: Scene {
  /// The window's scene ID.
  public static let id = "omnigent.local-server.logs"

  private let manager: LocalServerManager

  /// Creates the scene.
  /// - Parameter manager: Whose logs to show.
  public init(manager: LocalServerManager) {
    self.manager = manager
  }

  /// The window.
  public var body: some Scene {
    Window("Server Logs", id: Self.id) {
      LocalServerLogsView(manager: manager)
    }
    .defaultSize(width: 860, height: 520)
  }
}

/// The server's and host's recent output, newest at the bottom.
public struct LocalServerLogsView: View {
  enum Process: String, CaseIterable, Identifiable {
    case server = "Server"
    case host = "Host"

    var id: Self { self }
  }

  private let manager: LocalServerManager
  @State private var process = Process.server
  @State private var follows = true
  @State private var message: String?

  /// Creates the view.
  /// - Parameter manager: Whose logs to show.
  public init(manager: LocalServerManager) {
    self.manager = manager
  }

  /// The log and its controls.
  public var body: some View {
    VStack(spacing: 0) {
      if case .unavailable(let reason) = manager.capability {
        ContentUnavailableView(
          "No Local Server", systemImage: "lock.shield", description: Text(reason.explanation))
      } else {
        header
        Divider()
        lines
        Divider()
        footer
      }
    }
    .frame(minWidth: 520, minHeight: 280)
    .navigationTitle("Server Logs")
  }

  private var header: some View {
    HStack {
      Picker("Process", selection: $process) {
        ForEach(Process.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      Spacer()
      Toggle("Follow", isOn: $follows).toggleStyle(.checkbox)
    }
    .controlSize(.small)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var log: LocalProcessLog {
    process == .server ? manager.serverLog : manager.hostLog
  }

  private var lines: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 1) {
          if log.droppedLineCount > 0 {
            Text("\(log.droppedLineCount) earlier lines not kept")
              .foregroundStyle(.tertiary)
          }
          ForEach(log.lines) { line in
            Text(line.text.isEmpty ? " " : line.text)
              .foregroundStyle(color(line.source))
              .frame(maxWidth: .infinity, alignment: .leading)
              .id(line.id)
          }
        }
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .padding(10)
      }
      .background(Color(nsColor: .textBackgroundColor))
      .overlay {
        if log.lines.isEmpty {
          ContentUnavailableView(
            "No Output Yet", systemImage: "text.alignleft",
            description: Text(
              "Output appears here once the \(process.rawValue.lowercased()) starts."))
        }
      }
      .onChange(of: log.lines.last?.id, initial: true) { _, last in
        guard follows, let last else { return }
        proxy.scrollTo(last, anchor: .bottom)
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      LocalStatusDot(tone: process == .server ? manager.server.tone : manager.host.tone)
      Text(message ?? (process == .server ? manager.server.summary : manager.host.summary))
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.text, forType: .string)
      }
      .disabled(log.lines.isEmpty)
      Button("Clear") { log.clear() }
        .disabled(log.lines.isEmpty)
      Button("Open Log Folder") { message = LocalServerActions.revealLogFolder(manager) }
    }
    .controlSize(.small)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func color(_ source: LocalLogSource) -> Color {
    // The CLI mirrors its logs to standard error, so both pipes read as primary text.
    switch source {
    case .standardOutput, .standardError: .primary
    case .app: .accentColor
    }
  }
}
