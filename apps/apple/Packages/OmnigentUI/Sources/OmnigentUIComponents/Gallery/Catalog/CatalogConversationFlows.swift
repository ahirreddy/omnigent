import SwiftUI

/// Flows inside a session: starting one, answering requests, sub-agents and steering.
enum ConversationFlowCatalog {
  static var entries: [CatalogEntry] {
    [
      .flow(
        .newSession, "new-session", "New Session to Finished",
        summary: "Start a session: pick the agent and model, send, watch it stream, see it finish.",
        systemImage: "plus.bubble", keywords: ["start", "send", "streaming", "finished"],
        script: newSession,
        live: { context in AnyView(CatalogScenarioPage(.newSession, context: context)) }),
      .flow(
        .decisions, "approval", "Approval",
        summary:
          "A request arrives, you review it, then approve, reject or tell the agent instead.",
        systemImage: "hand.raised", keywords: ["approve", "reject", "feedback", "dock"],
        script: approval, live: { _ in AnyView(DecisionPlayground()) }),
      .flow(
        .transcript, "subagent", "Sub-agent Blocks",
        summary: "A child agent needs approval; you answer from the parent and open the child.",
        systemImage: "arrow.triangle.branch", keywords: ["child", "parent", "blocked"],
        script: subagent, live: { _ in AnyView(SubagentPlayground()) }),
      .flow(
        .composer, "queue-steer-stop", "Queue, Steer and Stop",
        summary: "Typing while the agent works: steer now, queue for later, or stop the turn.",
        systemImage: "list.number", keywords: ["queue", "steer", "stop", "interrupt"],
        script: steering, live: { _ in AnyView(NavigationStack { ComposerPlayground() }) }),
    ]
  }

  // MARK: New session

  typealias Step<Model> = CatalogFlowScript<Model>.Step

  static var newSession: CatalogFlowScript<PlaygroundModel> {
    CatalogFlowScript(
      initial: { context in PlaygroundModel(scenario: .newSession, preferences: context.preferences)
      },
      steps: [
        Step("page", "New session page", note: "Command-N or New Session opens the start page."),
        Step("agent", "Pick the agent", note: "The agent menu in the start composer.") { model in
          let agents = model.startComposer.configuration?.harnessChoices ?? []
          model.startComposer.configuration?.selectedAgentId = agents.last?.id
        },
        Step("model", "Pick the model", note: "The model menu sits beside the agent.") { model in
          let models = model.startComposer.configuration?.modelOptions ?? []
          model.startActions.selectModel?(models.last?.id)
        },
        Step(
          "draft", "Type the first message", note: "Return sends; Shift-Return adds a line."
        ) { model in
          model.startDraft = "Add a retry budget to the SSE reconnect and test it"
        },
        Step("send", "Send", note: "The session opens and the first turn starts.") { model in
          model.startActions.send()
        },
        Step("streaming", "Streaming", note: "Output streams in; Stop is in reach.") { model in
          FlowSamples.stream(model, text: FlowSamples.partialReply)
        },
        Step("finished", "Finished", note: "The turn ends; the composer is ready again.") { model in
          FlowSamples.stream(model, text: FlowSamples.fullReply)
          PageSamples.finish(model)
        },
      ],
      render: { model, context in
        AnyView(CatalogShell(model: model.wrappedValue, screen: context.screen))
      })
  }

  // MARK: Approval

  static var approval: CatalogFlowScript<DecisionFlowModel> {
    let card = PreviewData.claudeBash
    return CatalogFlowScript(
      initial: { _ in DecisionFlowModel() },
      steps: [
        Step("working", "The agent is working", note: "A normal running turn."),
        Step(
          "arrives", "A request arrives",
          note: "The dock appears above the composer; the session moves to Needs you."
        ) { model in model.receive(card) },
        Step("review", "Review", note: "Review (or Return) opens the whole request.") { model in
          model.isDockExpanded = true
        },
        Step(
          "approve", "Approve", note: "Command-Return approves; the turn continues.",
          branchesFrom: "review"
        ) { model in model.respond(card, .approve) },
        Step(
          "reject", "Reject", note: "The agent is told no and stops this action.",
          branchesFrom: "review"
        ) { model in model.respond(card, .decline) },
        Step(
          "tell", "Tell the agent instead", note: "The reply goes to the agent with the rejection.",
          branchesFrom: "review"
        ) { model in model.drafts.drafts[card.id] = DecisionSamples.feedbackDraft },
        Step("tell-sent", "Reply sent", note: "The agent reads the reply and adjusts.") { model in
          model.respond(
            card, .declineWithFeedback(feedback: DecisionSamples.feedbackDraft.feedback))
        },
      ],
      render: { model, _ in AnyView(DecisionFlowScreen(model: model)) })
  }

  // MARK: Sub-agent

  static var subagent: CatalogFlowScript<SubagentFlowModel> {
    let card = PreviewData.subagentCommand
    return CatalogFlowScript(
      initial: { _ in SubagentFlowModel() },
      steps: [
        Step("running", "Children running", note: "Three sub-agents work for the parent."),
        Step(
          "blocked", "A child blocks",
          note: "The migration check needs approval; the group shows Needs you."
        ) { model in model.parent = PreviewData.subagentConversation },
        Step("answer", "Answer from the parent", note: "Approve in the parent's group.") { model in
          model.respond(card, .approve)
        },
        Step("open-child", "Open the child", note: "The child's transcript routes back.") { model in
          model.open("sess_c1")
        },
        Step("back", "Back to the parent", note: "The banner returns to the parent.") { model in
          model.open(PreviewData.sessionID)
        },
      ],
      render: { model, _ in AnyView(SubagentFlowScreen(model: model)) })
  }

  // MARK: Queue, steer and stop

  static var steering: CatalogFlowScript<SteeringFlowModel> {
    CatalogFlowScript(
      initial: { _ in SteeringFlowModel() },
      steps: [
        Step("running", "The agent is working", note: "Stop is always in reach while it runs."),
        Step(
          "typed", "Type while it works",
          note: "The placeholder and Send say what a send does: steer now."
        ) { model in model.draft = "Also cover the expiry edge case" },
        Step("steer", "Send steers", note: "Return sends into the running turn.") { model in
          model.steer()
        },
        Step(
          "queue", "Queue instead",
          note: "Option-Command-Return (or Send's menu) queues it after this turn."
        ) { model in
          model.draft = "Then update the changelog"
          model.queueDraft()
        },
        Step("queue-more", "Queue another", note: "Queued messages keep their order.") { model in
          model.draft = "And open a pull request"
          model.queueDraft()
        },
        Step("stop", "Stop", note: "Esc or Stop ends the turn; the queue waits.") { model in
          model.stop()
        },
        Step("send-queued", "Send a queued message now", note: "From the queue's menu.") { model in
          if let first = model.composer.queue.first { model.sendNow(first) }
        },
      ],
      render: { model, _ in AnyView(SteeringFlowScreen(model: model)) })
  }
}

enum FlowSamples {
  static let partialReply = "I'll add a retry budget to the reconnect loop. First, the current"
  static let fullReply = """
    Added a retry budget to the SSE reconnect: five attempts with jittered backoff, then the \
    connection reports failure instead of retrying forever.

    - `client-core/src/sse/reconnect.rs`: the budget and backoff
    - `tests/reconnect_budget.rs`: three new tests, all passing
    """

  /// The sample session mid-turn, with no request waiting.
  static var working: ConversationViewState {
    var state = PreviewData.shellConversation
    state.decisions = []
    state.header.status = .running
    return state
  }

  /// Puts `text` in the session's live assistant row.
  static func stream(_ model: PlaygroundModel, text: String) {
    guard let index = model.conversation.rows.lastIndex(where: { $0.role == .assistant }) else {
      return
    }
    model.conversation.rows[index].text = text
    model.conversation.revision += 1
  }
}

/// The approval flow's state: the conversation, the composer and the dock's drafts.
struct DecisionFlowModel {
  var conversation = FlowSamples.working
  var composer = PreviewData.sessionComposer
  var isDockExpanded = false
  /// Shared with the dock, so a step can open the reply field.
  let drafts = DecisionDrafts()

  mutating func receive(_ card: DecisionCard) {
    conversation.decisions = [card]
    conversation.header.status = .needsResponse
    conversation.revision += 1
    composer = DecisionSamples.composer
  }

  mutating func respond(_ card: DecisionCard, _ response: DecisionResponse) {
    conversation.decisionPhases[card.id] = .answered(summary: response.summary)
    conversation.header.status = .running
    conversation.revision += 1
    composer = PreviewData.sessionComposer
  }
}

/// The conversation as the session page lays it out: transcript, dock and composer, sharing
/// the flow's drafts.
private struct DecisionFlowScreen: View {
  @Binding var model: DecisionFlowModel

  var body: some View {
    NavigationStack {
      TranscriptView(state: model.conversation, actions: actions)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          VStack(spacing: 0) {
            DecisionDock(state: model.conversation, actions: actions)
            ComposerView(
              draft: .constant(""), state: model.composer, actions: GalleryActions.composer)
          }
        }
        .themeCanvas()
        .navigationTitle(model.conversation.header.title)
    }
    .catalogNavigationBar(model.conversation.header.title)
    .environment(model.drafts)
    .environment(\.decisionDockStartsExpanded, model.isDockExpanded)
  }

  private var actions: ConversationActions {
    ConversationActions(
      respond: { card, response in model.respond(card, response) },
      validateForm: PreviewData.validate)
  }
}

/// The sub-agent flow's state: the parent and, when opened, a child.
struct SubagentFlowModel {
  var parent = Self.running
  var child: ConversationViewState?

  /// The parent before the child blocks: no mirrored request yet.
  static var running: ConversationViewState {
    var state = PreviewData.subagentConversation
    state.decisions = []
    return state
  }

  mutating func respond(_ card: DecisionCard, _ response: DecisionResponse) {
    parent.decisionPhases[card.id] = .answered(summary: response.summary)
    if let index = parent.sections.firstIndex(where: { $0.sessionId == card.targetSessionId }) {
      let section = parent.sections[index]
      parent.sections[index] = PreviewData.childSection(
        card.targetSessionId, title: section.title, state: .running, agent: "Codex",
        goal: section.details.first { $0.id == "goal" }?.text,
        activity: "Running the migration check", startedAgo: 150)
    }
    parent.revision += 1
  }

  mutating func open(_ id: String) {
    guard id != parent.header.id,
      let section = parent.sections.first(where: { $0.sessionId == id })
    else {
      child = nil
      return
    }
    var state = PreviewData.childConversation
    state.header.id = id
    state.header.title = section.title
    child = state
  }
}

private struct SubagentFlowScreen: View {
  @Binding var model: SubagentFlowModel
  @State private var draft = ""

  var body: some View {
    NavigationStack {
      ConversationScreen(
        state: model.child ?? model.parent, composer: PreviewData.sessionComposer, draft: $draft,
        showsInspector: .constant(false), actions: actions,
        composerActions: GalleryActions.composer)
    }
    .catalogNavigationBar((model.child ?? model.parent).header.title)
  }

  private var actions: ConversationActions {
    var actions = ConversationActions(
      openSession: { model.open($0) }, respond: { model.respond($0, $1) },
      validateForm: PreviewData.validate)
    actions.openChild = { model.open($0) }
    return actions
  }
}

/// The steering flow's state: a running conversation, its composer and the draft.
struct SteeringFlowModel {
  var conversation = FlowSamples.working
  var composer = ComposerSamples.runningEmpty
  var draft = ""
  private var nextID = 0

  mutating func steer() {
    append(user: draft)
    draft = ""
  }

  mutating func queueDraft() {
    composer.queue.append(QueuedMessage(id: "flow-q\(nextID)", text: draft))
    nextID += 1
    draft = ""
  }

  mutating func stop() {
    if let index = conversation.rows.lastIndex(where: \.isStreaming) {
      conversation.rows[index].isStreaming = false
      conversation.rows[index].interrupted = true
    }
    conversation.header.status = .idle
    conversation.revision += 1
    composer.isRunning = false
  }

  mutating func sendNow(_ message: QueuedMessage) {
    composer.queue.removeAll { $0.id == message.id }
    append(user: message.text)
    conversation.header.status = .running
    composer.isRunning = true
  }

  private mutating func append(user text: String) {
    conversation.rows.append(Row(id: "flow-u\(nextID)", role: .user, text: text))
    nextID += 1
    conversation.revision += 1
  }
}

private struct SteeringFlowScreen: View {
  @Binding var model: SteeringFlowModel

  var body: some View {
    NavigationStack {
      ConversationScreen(
        state: model.conversation, composer: model.composer, draft: $model.draft,
        showsInspector: .constant(false), actions: GalleryActions.conversation,
        composerActions: actions)
    }
    .catalogNavigationBar(model.conversation.header.title)
  }

  private var actions: ComposerActions {
    ComposerActions(
      send: {
        model.composer.isRunning
          ? model.steer() : model.sendNow(QueuedMessage(id: "send", text: model.draft))
      },
      interrupt: { model.stop() },
      extras: ComposerExtraActions(
        sendQueuedNow: { model.sendNow($0) },
        removeQueued: { message in model.composer.queue.removeAll { $0.id == message.id } },
        queueDraft: { model.queueDraft() }))
  }
}
