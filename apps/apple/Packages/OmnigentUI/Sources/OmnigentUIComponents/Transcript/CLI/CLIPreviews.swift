public import SwiftUI

/// Sample CLI conversations, matching the reference Codex CLI screenshots.
nonisolated public enum CLIPreviewScenario: String, Hashable, Sendable, CaseIterable,
  Identifiable
{
  /// "this is a test" and the markdown and table sample.
  case markdown
  /// Two sub-agents started and completed, then the combined answer with a table.
  case agents
  /// A pending command approval inline and in the dock.
  case approval
  /// An answer still streaming, with a tool running.
  case streaming

  /// The scenario itself.
  public var id: Self { self }

  /// The display title.
  public var title: String {
    switch self {
    case .markdown: "Markdown and tables"
    case .agents: "Multi-agent demo run"
    case .approval: "Approval"
    case .streaming: "Streaming"
    }
  }
}

enum CLIPreviewData {
  static let markdownAnswer = """
    ## Markdown sample

    - **Bold**
    - *Italic*
    - `inline code`
    - [A link](https://example.com)

    > A short blockquote.

    ## Table sample

    | Format | Example |
    | --- | --- |
    | Markdown | Headings, lists, quotes |
    | Table | Rows and columns |
    | Code | `print("Hello!")` |
    """

  static let styleAnswer = """
    My CLI output is mostly text, with Markdown-style formatting when the terminal supports \
    it: headings, lists, tables, and code blocks. Tool activity may also appear as separate \
    status or command sections.

    User inputs don\u{2019}t always have a different background color. That depends on the CLI \
    or terminal app and its theme; I don\u{2019}t control those colors.
    """

  static let demoIntro = """
    I\u{2019}ll run two agents on the same small sample task, then combine their replies into a \
    compact comparison so you can see the progress, tool activity, and final formatting.
    """

  static let demoAnswer = """
    ## Demo run

    I started two agents with separate formatting tasks. Both finished:

    1. One drafted a fictional weekend itinerary.
    2. The other made a table of cozy activity ideas.
    3. I\u{2019}ve combined their outputs below.

    ### Weekend in Mossbell

    1. **Saturday morning:** Browse the cloudberry market.
    2. **Saturday afternoon:** Ride the tiny ferry around Mirrorpond.
    3. **Sunday:** Visit the hilltop clock garden before heading home.

    | Option | Time | Mood |
    | --- | --- | --- |
    | Cocoa & Cloud Watching | Saturday afternoon | Dreamy |
    | Blanket Fort Book Club | Saturday evening | Cozy |
    | Pancake Picnic Indoors | Sunday morning | Playful |
    """

  static let streamingAnswer = """
    ## Plan

    I\u{2019}m checking the refresh path first:

    1. Read `auth/refresh.rs`
    2. Run the **auth** tests
    3. Summarize the
    """

  static func time(_ hour: Int, _ minute: Int) -> Date {
    Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
  }

  static func user(_ id: String, _ text: String) -> Row {
    Row(id: id, role: .user, text: text)
  }

  static func answer(_ id: String, _ text: String, response: String, streaming: Bool = false)
    -> Row
  {
    Row(id: id, role: .assistant, text: text, isStreaming: streaming, responseId: response)
  }

  static func agent(_ id: String, _ path: String, response: String, running: Bool = false)
    -> [Row]
  {
    let call = Row(
      id: "\(id)-call", role: .tool, text: path,
      activity: Activity(
        kind: .toolCall, title: "spawn_agent", summary: path,
        status: running ? "in_progress" : "completed"),
      callId: id, responseId: response)
    guard !running else { return [call] }
    let result = Row(
      id: "\(id)-result", role: .tool, text: "done",
      activity: Activity(
        kind: .toolResult, title: "spawn_agent", summary: "done", status: "completed",
        details: [DetailSection(id: "output", title: "Output", text: "Finished \(path)")]),
      callId: id, responseId: response)
    return [call, result]
  }

  static func shell(_ id: String, _ command: String, output: String, response: String) -> [Row] {
    [
      Row(
        id: "\(id)-call", role: .tool, text: command,
        activity: Activity(
          kind: .toolCall, title: "shell", summary: command, status: "completed"),
        callId: id, responseId: response),
      Row(
        id: "\(id)-result", role: .tool, text: output,
        activity: Activity(
          kind: .toolResult, title: "shell", summary: output, status: "completed",
          details: [DetailSection(id: "output", title: "Output", text: output, isCode: true)]),
        callId: id, responseId: response),
    ]
  }

  static func conversation(_ scenario: CLIPreviewScenario) -> ConversationViewState {
    var state = ConversationViewState(
      header: SessionHeader(id: "sess_cli", title: "CLI style", status: .idle))
    switch scenario {
    case .markdown: markdownConversation(&state)
    case .agents: agentsConversation(&state)
    case .approval:
      state.rows =
        [
          user("u1", "run the auth tests and fix anything that fails"),
          answer("a1", "I\u{2019}ll run the auth suite first.", response: "r1"),
        ]
        + shell(
          "sh1", "git status --short", output: " M client-core/src/auth/refresh.rs",
          response: "r1")
      state.header.status = .needsResponse
      state.decisions = [PreviewData.codexCommand]
    case .streaming:
      state.rows =
        [user("u1", "why does the token refresh fail after sleep?")]
        + shell(
          "sh1", "rg -n \"expires_at\" client-core", output: "auth/refresh.rs:42: expires_at",
          response: "r1")
        + [answer("a1", streamingAnswer, response: "r1", streaming: true)]
      state.header.status = .running
    }
    state.revision = 1
    return state
  }

  private static func markdownConversation(_ state: inout ConversationViewState) {
    state.rows = [
      user("u1", "this is a test"), answer("a1", "Got it.", response: "r1"),
      user("u2", "this is anotehr test"),
      answer("a2", "Got it\u{2014}another test.", response: "r2"),
      user(
        "u3",
        "can you give me a markdown or table output? I'm just trying to get a sample of "
          + "differnet outputs you have"),
      answer("a3", markdownAnswer, response: "r3"),
    ]
    state.turnDurations = ["r1": 3, "r2": 1, "r3": 2]
    state.timestamps = ["a1": time(21, 45), "a2": time(21, 46), "a3": time(21, 46)]
  }

  private static func agentsConversation(_ state: inout ConversationViewState) {
    state.rows =
      [
        user(
          "u1",
          "can you describe your CLI style/output? are user inputs always a different "
            + "background color?"),
        answer("a1", styleAnswer, response: "r1"),
        user(
          "u2",
          "can you trigger some agents, and a multi step output - so that I can see some "
            + "output, some tool calls, and some further rendering?"),
        answer("a2", demoIntro, response: "r2"),
      ] + agent("ag1", "/root/sample_list", response: "r2")
      + agent("ag2", "/root/sample_table", response: "r2")
      + [answer("a3", demoAnswer, response: "r2")]
    state.turnDurations = ["r1": 3, "r2": 12]
    state.timestamps = ["a1": time(21, 47), "a3": time(21, 47)]
  }

  static func composer(_ scenario: CLIPreviewScenario) -> ComposerViewState {
    var state = PreviewData.idleSessionComposer
    state.placeholder = "Ask the agent to do anything"
    state.tray = ComposerTray(directory: "~/wt/jhaiku-fusion", branch: "main")
    state.configuration?.selectedEffort = "high"
    switch scenario {
    case .markdown, .agents:
      state.configuration?.errorMessage = "The model list is out of date."
      state.context?.unavailableReason = nil
    case .approval:
      state.placeholder = "Respond to the pending request above to continue"
    case .streaming:
      state.isRunning = true
      state.placeholder = ComposerViewState().placeholder
    }
    return state
  }
}

/// Public builders for the CLI style, for the gallery and snapshot tests.
public enum CLIPreviews {
  /// A whole conversation screen in CLI style.
  /// - Parameters:
  ///   - scenario: The sample conversation.
  ///   - rendering: Output rendering.
  ///   - width: Content width.
  ///   - theme: Theme.
  /// - Returns: The screen, themed.
  public static func screen(
    _ scenario: CLIPreviewScenario, rendering: OutputRendering = .styled,
    width: TranscriptContentWidth = .edgeToEdge, theme: OmnigentTheme = .nord
  ) -> some View {
    CLIPreviewScreen(scenario: scenario)
      .transcriptAppearance(
        TranscriptAppearance(style: .cli, contentWidth: width, outputRendering: rendering)
      )
      .omnigentTheme(theme)
  }

  /// The transcript alone in CLI style.
  /// - Parameters:
  ///   - scenario: The sample conversation.
  ///   - rendering: Output rendering.
  ///   - theme: Theme.
  /// - Returns: The transcript, themed.
  public static func transcript(
    _ scenario: CLIPreviewScenario, rendering: OutputRendering = .styled,
    theme: OmnigentTheme = .nord
  ) -> some View {
    TranscriptView(state: CLIPreviewData.conversation(scenario))
      .transcriptAppearance(TranscriptAppearance(style: .cli, outputRendering: rendering))
      .omnigentTheme(theme)
  }

  /// The CLI composer with its status line.
  /// - Parameters:
  ///   - scenario: The sample state.
  ///   - theme: Theme.
  /// - Returns: The composer, themed.
  public static func composer(
    _ scenario: CLIPreviewScenario = .markdown, theme: OmnigentTheme = .nord
  ) -> some View {
    CLIComposer(
      draft: .constant(""), state: CLIPreviewData.composer(scenario),
      actions: ComposerActions(send: {})
    )
    .background { CLICanvas() }
    .cliPalette()
    .transcriptAppearance(TranscriptAppearance(style: .cli))
    .omnigentTheme(theme)
  }
}

/// A sample conversation screen; answering the approval and sending work.
struct CLIPreviewScreen: View {
  let scenario: CLIPreviewScenario
  @State private var state: ConversationViewState
  @State private var draft = ""
  @State private var showsInspector = false

  init(scenario: CLIPreviewScenario) {
    self.scenario = scenario
    _state = State(initialValue: CLIPreviewData.conversation(scenario))
  }

  var body: some View {
    NavigationStack {
      ConversationScreen(
        state: state, composer: CLIPreviewData.composer(scenario), draft: $draft,
        showsInspector: $showsInspector,
        actions: ConversationActions(
          openSession: { _ in },
          respond: { card, response in
            state.decisionPhases[card.id] = .answered(summary: response.summary)
            state.revision += 1
          },
          forkFrom: { _ in }),
        composerActions: ComposerActions(send: { send() }))
    }
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    state.rows.append(Row(id: "local-\(state.rows.count)", role: .user, text: text))
    state.revision += 1
    draft = ""
  }
}

/// The playground's CLI scenario: a sample conversation with the style, output rendering, width
/// and theme switchable in place.
public struct CLIPlayground: View {
  @State private var scenario = CLIPreviewScenario.agents
  @State private var style = TranscriptStyle.cli
  @State private var rendering = OutputRendering.styled
  @State private var width = TranscriptContentWidth.edgeToEdge
  @State private var fontSize = TranscriptAppearance.defaultFontSize

  /// Creates the playground.
  public init() {}

  /// The playground.
  public var body: some View {
    CLIPreviewScreen(scenario: scenario)
      .id(scenario)
      .transcriptAppearance(
        TranscriptAppearance(
          style: style, contentWidth: width, outputRendering: rendering, fontSize: fontSize)
      )
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          Picker("Scenario", selection: $scenario) {
            ForEach(CLIPreviewScenario.allCases) { Text($0.title).tag($0) }
          }
          Picker("Style", selection: $style) {
            ForEach(TranscriptStyle.allCases) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          Picker("Output", selection: $rendering) {
            ForEach(OutputRendering.allCases) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          Picker("Width", selection: $width) {
            ForEach(TranscriptContentWidth.allCases) { Text($0.title).tag($0) }
          }
          Stepper("\(Int(fontSize)) pt", value: $fontSize, in: TranscriptAppearance.fontSizes)
        }
      }
      .accessibilityIdentifier("cli-playground")
  }
}
