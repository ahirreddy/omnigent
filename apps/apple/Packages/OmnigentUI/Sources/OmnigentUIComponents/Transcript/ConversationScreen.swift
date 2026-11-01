public import SwiftUI

/// Whether a session shows its chat transcript or its harness's terminal (TUI).
nonisolated public enum SessionViewMode: String, Hashable, Sendable, CaseIterable {
  /// The chat transcript and composer.
  case chat
  /// The harness's terminal surface (Claude Code, Codex, Pi and other native harnesses).
  case terminal
}

/// A whole conversation: the status header, the transcript (or the harness's terminal), plan,
/// pending decisions, composer and inspector, with the Conversation menu commands published for
/// the key window.
///
/// Drop it into the detail column of a `NavigationSplitView`. On compact width the inspector
/// becomes a sheet. Pending decisions stay docked in both modes.
public struct ConversationScreen<Terminal: View>: View {
  private let state: ConversationViewState
  private let composer: ComposerViewState
  @Binding private var draft: String
  @Binding private var showsInspector: Bool
  @Binding private var mode: SessionViewMode
  private let actions: ConversationActions
  private let composerActions: ComposerActions
  private let sessionNavigation: SessionCommandActions
  private let terminal: Terminal

  @State private var scrollRequest = 0
  @State private var focusRequest = 0
  @Environment(\.layoutWidth) private var layoutWidth

  /// Creates the screen with a terminal mode.
  /// - Parameters:
  ///   - state: The conversation; `terminalAvailable` enables the Terminal mode.
  ///   - composer: The composer state.
  ///   - draft: The draft text.
  ///   - showsInspector: Whether the inspector shows.
  ///   - mode: Chat or Terminal.
  ///   - actions: Conversation actions.
  ///   - composerActions: Composer actions.
  ///   - sessionNavigation: Previous and next session commands from the host's list.
  ///   - terminal: The terminal surface the app supplies (for example the libghostty view).
  public init(
    state: ConversationViewState, composer: ComposerViewState, draft: Binding<String>,
    showsInspector: Binding<Bool>, mode: Binding<SessionViewMode>,
    actions: ConversationActions, composerActions: ComposerActions,
    sessionNavigation: SessionCommandActions = SessionCommandActions(),
    @ViewBuilder terminal: () -> Terminal
  ) {
    self.state = state
    self.composer = composer
    _draft = draft
    _showsInspector = showsInspector
    _mode = mode
    self.actions = actions
    self.composerActions = composerActions
    self.sessionNavigation = sessionNavigation
    self.terminal = terminal()
  }

  /// The screen.
  public var body: some View {
    let showsTerminal = mode == .terminal && state.terminalAvailable
    Group {
      if showsTerminal {
        terminal
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("session-terminal")
      } else {
        TranscriptView(state: state, actions: actions, scrollToLatestRequest: scrollRequest)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      SessionHeaderView(state: state, showsTitle: layoutWidth == .compact)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        if !showsTerminal, let todos = state.section("todos"), !todos.details.isEmpty {
          PlanAccordion(section: todos)
        }
        DecisionDock(state: state, actions: actions)
        if !showsTerminal {
          ComposerView(
            draft: $draft, state: composer, actions: composerActions, focusRequest: focusRequest)
        } else if !state.decisions.isEmpty {
          Spacer().frame(height: 10)
        }
      }
      .background(.bar)
      .overlay(alignment: .top) { Divider() }
    }
    .inspector(isPresented: $showsInspector) {
      SessionInspectorView(state: state, actions: actions)
        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }
    .navigationTitle(state.header.title)
    #if os(macOS)
      .navigationSubtitle(state.header.settings?.modelLabel ?? "")
    #endif
    .toolbar {
      if state.terminalAvailable || state.terminalStartingUp {
        ToolbarItem(placement: .principal) {
          ViewModePicker(
            mode: $mode, terminalAvailable: state.terminalAvailable,
            terminalStartingUp: state.terminalStartingUp)
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          showsInspector.toggle()
        } label: {
          Label("Inspector", systemImage: "sidebar.trailing")
        }
        .help(showsInspector ? "Hide the inspector" : "Show the inspector")
        .accessibilityIdentifier("toggle-inspector")
      }
    }
    .focusedSceneValue(\.sessionCommands, commands)
  }

  private var commands: SessionCommandActions {
    let chat = mode == .chat || !state.terminalAvailable
    let canSend =
      chat && composer.availability == .available && composer.delivery == .idle
      && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !composer.attachments.isEmpty)
    var jump: (@MainActor () -> Void)?
    var focus: (@MainActor () -> Void)?
    if chat {
      jump = { scrollRequest += 1 }
      focus = { focusRequest += 1 }
    }
    var toggleMode: (@MainActor () -> Void)?
    if state.terminalAvailable {
      let binding = $mode
      toggleMode = { binding.wrappedValue = binding.wrappedValue == .chat ? .terminal : .chat }
    }
    return SessionCommandActions(
      send: canSend ? composerActions.send : nil,
      interrupt: composer.isRunning ? composerActions.interrupt : nil,
      jumpToLatest: jump, focusComposer: focus,
      toggleInspector: { showsInspector.toggle() },
      previousSession: sessionNavigation.previousSession,
      nextSession: sessionNavigation.nextSession,
      toggleViewMode: toggleMode)
  }
}

extension ConversationScreen where Terminal == EmptyView {
  /// Creates the screen without a terminal mode.
  /// - Parameters:
  ///   - state: The conversation.
  ///   - composer: The composer state.
  ///   - draft: The draft text.
  ///   - showsInspector: Whether the inspector shows.
  ///   - actions: Conversation actions.
  ///   - composerActions: Composer actions.
  ///   - sessionNavigation: Previous and next session commands from the host's list.
  public init(
    state: ConversationViewState, composer: ComposerViewState, draft: Binding<String>,
    showsInspector: Binding<Bool>, actions: ConversationActions, composerActions: ComposerActions,
    sessionNavigation: SessionCommandActions = SessionCommandActions()
  ) {
    self.init(
      state: state, composer: composer, draft: draft, showsInspector: showsInspector,
      mode: .constant(.chat), actions: actions, composerActions: composerActions,
      sessionNavigation: sessionNavigation
    ) {
      EmptyView()
    }
  }
}

/// The Chat and Terminal segmented switch.
struct ViewModePicker: View {
  @Binding var mode: SessionViewMode
  let terminalAvailable: Bool
  let terminalStartingUp: Bool

  var body: some View {
    Picker("View", selection: $mode) {
      Label("Chat", systemImage: "bubble.left.and.text.bubble.right").tag(SessionViewMode.chat)
      Label(terminalStartingUp ? "Starting Terminal" : "Terminal", systemImage: "apple.terminal")
        .tag(SessionViewMode.terminal)
        .selectionDisabled(!terminalAvailable)
    }
    .pickerStyle(.segmented)
    .labelStyle(.titleAndIcon)
    .fixedSize()
    .help(
      terminalAvailable ? "Switch between chat and the harness terminal" : "Starting the terminal"
    )
    .accessibilityIdentifier("session-view-mode")
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
