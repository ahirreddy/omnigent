import SwiftUI

/// "Set up Omnigent locally": what running on this Mac gives you, then Start (or Open, when the
/// server already runs; Install, when the CLI is missing).
struct LocalIntroView: View {
  let state: LocalSetupState
  let back: () -> Void
  let proceed: () -> Void

  var body: some View {
    AuthCard(
      systemImage: "laptopcomputer", title: "Set up Omnigent locally",
      subtitle:
        "Use Claude Code, Codex, Cursor and other local harnesses from one app. Keep history and context across harnesses, and import your existing chats."
    ) {
      EmptyView()
    } buttons: {
      AuthButton(title: "Back", kind: .cancel, identifier: "auth.back", action: back)
      AuthButton(
        title: actionTitle, kind: .primary, identifier: "auth.start-local", action: proceed)
    }
  }

  private var actionTitle: String {
    if state.isRunning { return "Open Omnigent" }
    if state.needsCLI { return "Install Omnigent" }
    return "Start Omnigent"
  }
}

/// The local server starting: its status, its latest output and, on failure, Try Again.
struct LocalProgressView: View {
  let state: LocalSetupState
  let actions: LocalSetupActions
  let back: () -> Void
  let retry: () -> Void

  var body: some View {
    AuthCard(
      systemImage: "exclamationmark.triangle", title: title, subtitle: subtitle,
      isProgress: failure == nil
    ) {
      if let failure {
        AuthBannerView(.notice(failure))
      }
      LogTail(lines: state.log)
      if let showLogs = actions.showLogs {
        Button("Show Server Logs", systemImage: "doc.text.magnifyingglass", action: showLogs)
          .controlSize(.small)
          .accessibilityIdentifier("auth.show-server-logs")
      }
    } buttons: {
      AuthButton(title: "Back", kind: .cancel, identifier: "auth.back", action: back)
      if failure != nil {
        AuthButton(
          title: "Try Again", kind: .primary, identifier: "auth.retry-local", action: retry)
      }
    }
  }

  private var failure: String? {
    switch state.server {
    case .failed(let message): ServerText.escaped(message, limit: 400)
    case .stopped, .busy, .running: nil
    }
  }

  private var title: String {
    if failure != nil { return "Omnigent didn\u{2019}t start" }
    return state.isRunning ? "Opening Omnigent" : "Starting Omnigent"
  }

  private var subtitle: String {
    switch state.server {
    case .running(let url): "Connecting to the local server at \(url)\u{2026}"
    case .busy(let summary): summary
    case .stopped: "Starting the local server\u{2026}"
    case .failed: "The local server stopped before it was ready."
    }
  }
}

/// The last lines of the server's output, as a small terminal.
private struct LogTail: View {
  let lines: [String]

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 1) {
          if lines.isEmpty {
            Text("Waiting for output\u{2026}").foregroundStyle(.secondary)
          }
          ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            Text(verbatim: line).id(index)
          }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
      }
      .frame(height: 150)
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: AuthMetrics.radius))
      .overlay {
        RoundedRectangle(cornerRadius: AuthMetrics.radius).strokeBorder(.separator, lineWidth: 0.5)
      }
      .onChange(of: lines.count) { _, count in
        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
      }
    }
    .accessibilityLabel("Server output")
    .accessibilityIdentifier("auth.local-log")
  }
}

/// "Install the Omnigent CLI": the install guide, then Check Again.
struct InstallCLIView: View {
  let state: LocalSetupState
  let actions: LocalSetupActions
  let back: () -> Void
  let start: () -> Void

  @Environment(\.openURL) private var openURL
  @State private var checked = false

  var body: some View {
    AuthCard(
      systemImage: "terminal", title: "Install the Omnigent CLI",
      subtitle:
        "Omnigent runs on this Mac through its command-line tool. Install it, check that `omnigent --version` works in a new Terminal window, then check again."
    ) {
      if let url = LocalSetupActions.installGuideURL {
        Button("Installation Instructions", systemImage: "safari") { openURL(url) }
          .accessibilityIdentifier("auth.install-guide")
      }
      if checked, case .missing(let reason) = state.cli {
        AuthBannerView(.notice(ServerText.escaped(reason, limit: 400)))
      }
    } buttons: {
      AuthButton(title: "Back", kind: .cancel, identifier: "auth.back", action: back)
      AuthButton(
        title: state.cli == .checking ? "Checking\u{2026}" : "Check Again", kind: .primary,
        isBusy: state.cli == .checking, identifier: "auth.recheck-cli"
      ) {
        checked = true
        actions.recheckCLI()
      }
      .disabled(state.cli == .checking)
    }
    .onChange(of: state.cli) { _, cli in
      if checked, cli == .found { start() }
    }
  }
}

/// "Where do you work today?": whether this Mac runs agents for the server being joined.
struct RunnerChoiceView: View {
  let serverUrl: String
  let directory: ServerDirectory
  let localSetup: LocalSetupState?
  let back: () -> Void
  let proceed: (Bool) -> Void

  @State private var hostHere = true

  var body: some View {
    AuthCard(
      systemImage: "desktopcomputer", title: "Where do you work today?",
      subtitle: "Join \(serverName) and choose where its agents run."
    ) {
      Toggle(isOn: $hostHere) {
        VStack(alignment: .leading, spacing: 2) {
          Text("This Mac")
          Text("The server will be able to run agents on this Mac, with your permissions.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      #if os(macOS)
        .toggleStyle(.checkbox)
      #endif
      .disabled(!canHost)
      .accessibilityIdentifier("auth.host-this-mac")
      if !canHost {
        FieldMessage(
          text:
            "Install the Omnigent CLI to run agents on this Mac. You can start hosting later from the Server menu.",
          isError: false)
      }
      Text(
        "Share sessions with your teammates, use Omnigent from any device, and keep sessions running while you\u{2019}re away."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    } buttons: {
      AuthButton(title: "Back", kind: .cancel, identifier: "auth.back", action: back)
      AuthButton(title: "Join", kind: .primary, identifier: "auth.join") {
        proceed(hostHere && canHost)
      }
    }
  }

  private var canHost: Bool {
    localSetup.map { !$0.needsCLI } ?? false
  }

  private var serverName: String {
    directory.managed.first { $0.url == serverUrl }.map {
      ServerText.escaped($0.displayName, limit: 80)
    } ?? ServerIdentity.hostLabel(serverUrl)
  }
}
