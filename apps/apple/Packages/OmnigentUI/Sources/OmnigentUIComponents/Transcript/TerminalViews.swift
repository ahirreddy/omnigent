public import SwiftUI

/// The terminal with the web's states: starting, sandbox offline, harness not running.
struct TerminalPane<Content: View>: View {
  let status: TerminalStatus
  let resume: (@MainActor () -> Void)?
  @ViewBuilder var content: Content

  var body: some View {
    switch status {
    case .ready, .none:
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("session-terminal")
    case .startingUp(let stage):
      VStack(spacing: 10) {
        ProgressView()
        Text(stage.map { "\($0)\u{2026}" } ?? "Starting up\u{2026}").font(.headline)
        Text("The terminal will connect automatically.").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("terminal-starting")
    case .sandboxOffline, .harnessNotRunning, .resuming:
      let sandbox = status == .sandboxOffline || status == .resuming
      ContentUnavailableView {
        Label(
          sandbox ? "The sandbox is offline." : "The harness is not running.",
          systemImage: "powersleep")
      } description: {
        Text(
          sandbox
            ? "Resume it to reconnect the terminal."
            : "Resume the session to reconnect the terminal.")
      } actions: {
        if let resume {
          Button(
            status == .resuming
              ? "Resuming\u{2026}" : (sandbox ? "Resume sandbox" : "Resume session"), action: resume
          )
          .buttonStyle(.bordered)
          .disabled(status == .resuming)
        }
      }
      .accessibilityIdentifier("terminal-offline")
    }
  }
}

/// The header's Info popover: the agent's tools and policies.
struct AgentInfoPopover: View {
  let info: AgentInfo

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(info.name).font(.headline)
      if !info.tools.isEmpty {
        Text("Tools").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        FlowLayout(spacing: 4) {
          ForEach(info.tools, id: \.self) { Pill(text: $0, systemImage: "wrench.and.screwdriver") }
        }
      }
      if !info.policies.isEmpty {
        Text("Policies").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(info.policies, id: \.self) { Label($0, systemImage: "hand.raised").font(.callout) }
      }
    }
    .padding(14)
    .frame(width: 300, alignment: .leading)
  }
}

/// A stand-in terminal surface for previews and the playground until the app supplies the real
/// one: a dark, monospaced TUI mock.
public struct TerminalPlaceholderView: View {
  private let harness: String?

  /// Creates the placeholder.
  /// - Parameter harness: The harness id, for the banner.
  public init(harness: String?) {
    self.harness = harness
  }

  /// The mock terminal.
  public var body: some View {
    let name = HarnessAppearance(harness: harness).label
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        line(
          "\u{256D}\u{2500} \(name) \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}", .cyan
        )
        line("\u{2502} cwd: /workspace/omnigent", .gray)
        line(
          "\u{2570}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}",
          .cyan)
        line("")
        line("> refactor the token refresh and add tests", .white)
        line("")
        line("\u{25CF} Read(client-core/crates/omnigent-core/src/auth/refresh.rs)", .green)
        line("  \u{23BF} Read 182 lines", .gray)
        line("\u{25CF} Bash(cargo test -p omnigent-core auth)", .green)
        line("  \u{23BF} test result: FAILED. 41 passed; 1 failed", .red)
        line("\u{25CF} Update(auth/refresh.rs)", .green)
        line("  \u{23BF} +4 -3", .gray)
        line("")
        line("\u{2733} Re-running the expiry test\u{2026} (esc to interrupt)", .orange)
        line("")
        line("Terminal surface placeholder. The app supplies the real terminal view.", .gray)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color(red: 0.08, green: 0.08, blue: 0.1))
    .environment(\.colorScheme, .dark)
    .accessibilityLabel("Terminal placeholder for \(name)")
  }

  private func line(_ text: String, _ color: Color = .white) -> some View {
    Text(verbatim: text)
      .font(.system(.callout, design: .monospaced))
      .foregroundStyle(color)
      .textSelection(.enabled)
  }
}
