import Foundation

/// Sample composer state: the approval modes per harness (the core's vocabulary), the agent,
/// model and effort picker, the execution context and a queue.
enum ComposerSamples {
  /// Codex's live approval modes.
  static func codexModes(selected: String? = "approve-for-me") -> ApprovalModes {
    ApprovalModes(
      title: "Codex approvals",
      options: [
        ApprovalModeOption(
          id: "ask-for-approval", label: "Auto-edit",
          detail: "Edits and runs in the workspace; asks before network access or outside edits",
          harnessLabel: "Ask for approval", risk: .autoEdit),
        ApprovalModeOption(
          id: "approve-for-me", label: "Auto-approve",
          detail: "Asks only for actions it detects as unsafe", harnessLabel: "Approve for me",
          risk: .autoApprove),
        ApprovalModeOption(
          id: "full-access", label: "Full access",
          detail: "Edits any file and uses the internet without asking",
          harnessLabel: "Full Access", risk: .fullAccess),
      ], selectedID: selected)
  }

  /// Claude Code's shift+tab modes.
  static func claudeModes(selected: String? = "default") -> ApprovalModes {
    ApprovalModes(
      title: "Claude Code approvals",
      options: [
        ApprovalModeOption(
          id: "default", label: "Ask first", detail: "Asks before edits and commands",
          harnessLabel: "Manual", risk: .ask),
        ApprovalModeOption(
          id: "acceptEdits", label: "Auto-edit",
          detail: "Applies file edits without asking; commands still ask",
          harnessLabel: "Accept edits", risk: .autoEdit),
        ApprovalModeOption(
          id: "plan", label: "Plan only", detail: "Plans and reads; makes no edits",
          harnessLabel: "Plan", risk: .readOnly),
        ApprovalModeOption(
          id: "auto", label: "Auto-approve",
          detail: "Runs without asking; a classifier blocks risky actions", harnessLabel: "Auto",
          risk: .autoApprove),
      ], selectedID: selected)
  }

  static let codexConfiguration = ComposerConfiguration(
    harness: "codex-native", agentName: "Codex",
    harnessChoices: [
      HarnessChoice(id: "agent_codex", name: "Codex", harness: "codex-native"),
      HarnessChoice(id: "agent_claude", name: "Claude Code", harness: "claude-native"),
      HarnessChoice(
        id: "agent_pi", name: "Pi", harness: "pi-native",
        unavailableReason: "Sign in to this harness on the host first."),
    ], selectedAgentId: "agent_codex", modelOptions: PreviewData.models, selectedModelId: nil,
    selectedEffort: "high")

  static let context = ExecutionContext(
    agent: "Codex", harness: "codex-native", host: "Mac Studio", isHostOnline: true,
    server: "Omnigent (team)", directory: "/Users/ahir/src/omnigent", branch: "auth-refresh",
    sandbox: "None (runs on the host)")

  static var idle: ComposerViewState {
    ComposerViewState(
      configuration: codexConfiguration,
      hosts: ComposerHosts(hosts: PreviewData.hosts.hosts, selectedID: "host_mbp", isLocked: true),
      approvalModes: codexModes(),
      tray: ComposerTray(pullRequest: "#2041", contextFraction: 0.38),
      slashCommands: PreviewData.slashCommands, context: context, canSteer: true)
  }

  static var running: ComposerViewState {
    var state = idle
    state.isRunning = true
    state.tray?.contextFraction = 0.66
    state.queue = [
      QueuedMessage(id: "q1", text: "Also update the changelog when you're done"),
      QueuedMessage(
        id: "q2", text: "Then run the auth tests on the CI runner",
        state: .failed(message: "The host is offline.")),
    ]
    return state
  }

  static var fullAccess: ComposerViewState {
    var state = idle
    state.approvalModes = codexModes(selected: "full-access")
    return state
  }

  static var offline: ComposerViewState {
    var state = idle
    state.context?.isHostOnline = false
    state.context?.unavailableReason =
      "This session's host is offline. Reconnect that host, or create a new session on a "
      + "connected host from Sessions. Your draft stays here."
    return state
  }

  static var start: ComposerViewState {
    ComposerViewState(
      configuration: ComposerConfiguration(
        harness: "claude-native", agentName: "Claude Code",
        harnessChoices: [
          HarnessChoice(id: "agent_claude", name: "Claude Code", harness: "claude-native"),
          HarnessChoice(id: "agent_codex", name: "Codex", harness: "codex-native"),
        ], selectedAgentId: "agent_claude",
        modelOptions: [
          ModelOption(
            id: "opus", displayName: "Claude Opus 5", defaultReasoningEffort: "high",
            supportedReasoningEfforts: ["low", "medium", "high", "max"], isDefault: true),
          ModelOption(id: "sonnet", displayName: "Claude Sonnet 5"),
        ]),
      placeholder: "Describe a task to start a new session\u{2026}", hosts: PreviewData.hosts,
      tray: ComposerTray(
        directory: "/Users/ahir/src/universe",
        recentDirectories: ["/Users/ahir/src/universe", "/Users/ahir/src/omnigent"],
        worktree: "No worktree", worktrees: ["auth-refresh", "release-2026.11"]),
      slashCommands: PreviewData.slashCommands, purpose: .start,
      context: ExecutionContext(
        agent: "Claude Code", harness: "claude-native", host: "Ahir's MacBook Pro",
        isHostOnline: true,
        server: ExecutionContext.serverDisplayName(
          name: nil, baseURL: "http://127.0.0.1:6767"),
        directory: "/Users/ahir/src/universe", sandbox: "None (runs on the host)"))
  }

  static var startUnavailable: ComposerViewState {
    var state = start
    state.hosts?.selectedID = "host_ci"
    state.context?.host = "CI runner"
    state.context?.isHostOnline = false
    state.context?.unavailableReason = "Connect this host before starting a session."
    state.availability = .unavailable(reason: "Connect this host before starting a session.")
    return state
  }
}
