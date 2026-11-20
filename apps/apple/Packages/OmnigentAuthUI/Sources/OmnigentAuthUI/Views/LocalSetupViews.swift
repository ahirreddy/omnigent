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
      systemImage: "terminal", title: "Install the Omnigent CLI", subtitle: subtitle,
      isProgress: isInstalling
    ) {
      if let url = LocalSetupActions.installGuideURL {
        Button("Installation Instructions", systemImage: "safari") { openURL(url) }
          .accessibilityIdentifier("auth.install-guide")
      }
      if case .failed(let reason) = state.install {
        AuthBannerView(.notice(ServerText.escaped(reason, limit: 400)))
      } else if checked, !isInstalling, case .missing(let reason) = state.cli {
        AuthBannerView(.notice(ServerText.escaped(reason, limit: 400)))
      }
      if isInstalling || state.install != .idle { LogTail(lines: state.log) }
    } buttons: {
      AuthButton(title: "Back", kind: .cancel, identifier: "auth.back", action: back)
        .disabled(isInstalling)
      AuthButton(
        title: state.cli == .checking ? "Checking\u{2026}" : "Check Again",
        kind: actions.installCLI == nil ? .primary : .secondary,
        isBusy: state.cli == .checking, identifier: "auth.recheck-cli"
      ) {
        checked = true
        actions.recheckCLI()
      }
      .disabled(state.cli == .checking || isInstalling)
      if let install = actions.installCLI {
        AuthButton(
          title: isInstalling ? "Installing\u{2026}" : "Install", kind: .primary,
          isBusy: isInstalling, identifier: "auth.install-cli"
        ) {
          checked = true
          install()
        }
        .disabled(isInstalling)
      }
    }
    .onChange(of: state.cli) { _, cli in
      if checked, cli == .found { start() }
    }
  }

  private var isInstalling: Bool { state.install == .installing }

  private var subtitle: String {
    if isInstalling {
      return "Installing uv and the Omnigent CLI. This can take a few minutes."
    }
    return actions.installCLI == nil
      ? "Omnigent runs on this Mac through its command-line tool. Install it, check that `omnigent --version` works in a new Terminal window, then check again."
      : "Omnigent runs on this Mac through its command-line tool. Install it here, or follow the instructions and check again."
  }
}

/// "Where do you work today?": whether this Mac runs agents for the server being joined. Without
/// the CLI, where the app can install it, "How do you want to join?": Just join, or Install CLI
/// first, as the web's runner step.
struct RunnerChoiceView: View {
  let serverUrl: String
  let directory: ServerDirectory
  let localSetup: LocalSetupState?
  /// The app can install the CLI here.
  var canInstall = false
  let back: () -> Void
  let proceed: (RunnerChoice) -> Void

  @State private var hostHere = true
  @State private var installs = false

  var body: some View {
    if offersInstall { joinChoice } else { runnerChoice }
  }

  /// Without the CLI: open the server as it is, or install the CLI first.
  private var joinChoice: some View {
    AuthCard(
      systemImage: "desktopcomputer", title: "How do you want to join?",
      subtitle: "Join \(serverName) and choose where its agents run."
    ) {
      Picker("How do you want to join?", selection: $installs) {
        choiceLabel(
          "Just join", detail: "Open the server without installing anything.",
          systemImage: "arrow.right.circle"
        ).tag(false)
        choiceLabel(
          "Install CLI first",
          detail: "The server will be able to run agents on this Mac.",
          systemImage: "laptopcomputer"
        ).tag(true)
      }
      .labelsHidden()
      #if os(macOS)
        .pickerStyle(.radioGroup)
      #else
        .pickerStyle(.inline)
      #endif
      .accessibilityIdentifier("auth.join-choice")
    } buttons: {
      AuthButton(title: "Back", kind: .cancel, identifier: "auth.back", action: back)
      AuthButton(
        title: installs ? "Install Omnigent" : "Open Omnigent", kind: .primary,
        identifier: "auth.join"
      ) {
        proceed(installs ? .installFirst : .join)
      }
    }
  }

  private func choiceLabel(_ title: String, detail: String, systemImage: String) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: systemImage)
    }
  }

  private var offersInstall: Bool {
    canInstall && localSetup?.needsCLI == true
  }

  private var runnerChoice: some View {
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
        proceed(hostHere && canHost ? .host : .join)
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

/// "Install CLI first": installing the CLI before joining, with Cancel while it runs (the
/// installer keeps going, but the join doesn't wait for it), and on failure Back, Continue
/// Anyway (join without hosting) and Retry, as the web's setup step.
struct RunnerInstallView: View {
  let state: LocalSetupState
  let back: () -> Void
  let retry: () -> Void
  let join: () -> Void
  let installed: () -> Void

  var body: some View {
    AuthCard(
      systemImage: failure == nil ? "terminal" : "exclamationmark.triangle",
      title: failure == nil ? "Installing the Omnigent CLI" : "Couldn\u{2019}t set up Omnigent",
      subtitle: failure == nil
        ? "Installing uv and the Omnigent CLI. This can take a few minutes."
        : "The CLI didn\u{2019}t install, so this Mac can\u{2019}t run agents yet.",
      isProgress: failure == nil
    ) {
      if let failure { AuthBannerView(.notice(ServerText.escaped(failure, limit: 400))) }
      LogTail(lines: state.log)
    } buttons: {
      if failure == nil {
        AuthButton(title: "Cancel", kind: .cancel, identifier: "auth.cancel-install", action: back)
      } else {
        AuthButton(title: "Back", kind: .cancel, identifier: "auth.back", action: back)
        AuthButton(
          title: "Continue Anyway", kind: .secondary, identifier: "auth.continue-anyway",
          action: join)
        AuthButton(title: "Retry", kind: .primary, identifier: "auth.retry-install", action: retry)
      }
    }
    .onChange(of: state.cli, initial: true) { _, cli in
      if cli == .found { installed() }
    }
  }

  private var failure: String? {
    if case .failed(let reason) = state.install { return reason }
    return nil
  }
}
