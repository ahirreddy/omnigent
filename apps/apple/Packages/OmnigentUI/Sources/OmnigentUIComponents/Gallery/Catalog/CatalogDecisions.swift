import SwiftUI

/// Decisions: every card kind, every phase, the dock, the iPhone sheet and summary rows.
enum DecisionCatalog {
  static var entries: [CatalogEntry] {
    [
      .component(
        .decisions, "card-kinds", "Decision Card",
        summary: "Every request kind the agent can raise, pending and answerable.",
        systemImage: "hand.raised", canvas: .column(width: 640),
        keywords: ["approval", "permission", "question", "form", "plan", "command"],
        states: kinds.map { kind in
          CatalogState(kind.id, kind.title) { DecisionSample(card: kind.value) }
        },
        live: { _ in AnyView(DecisionPlayground()) }),
      .component(
        .decisions, "card-phases", "Decision Card Phases",
        summary:
          "One request through its lifecycle: pending, sending, failed, answered, read only.",
        systemImage: "checklist", canvas: .column(width: 640),
        keywords: ["sending", "failed", "answered", "read only", "disabled"],
        states: [
          CatalogState("pending", "Pending") { DecisionSample(card: PreviewData.approval) },
          CatalogState("feedback", "Tell the agent instead", note: "The reply field is open.") {
            DecisionSample(card: PreviewData.claudeBash, draft: DecisionSamples.feedbackDraft)
          },
          CatalogState("resolving", "Sending") {
            DecisionSample(card: PreviewData.approval, phase: .resolving)
          },
          CatalogState("failed", "Send failed") {
            DecisionSample(
              card: PreviewData.approval,
              phase: .failed(message: "Could not send your response: the server returned 503."))
          },
          CatalogState("answered", "Answered") {
            DecisionSample(card: PreviewData.approval, phase: .answered(summary: "Approved"))
          },
          CatalogState("read-only", "Read only", note: "A viewer of a shared session.") {
            DecisionSample(card: PreviewData.codexCommand, isReadOnly: true)
          },
          CatalogState("compact", "Compact rows") {
            CatalogStack(spacing: Theme.Spacing.medium) {
              ForEach([PreviewData.claudeBash, PreviewData.codexCommand, PreviewData.choice]) {
                DecisionCardView(card: $0, style: .compact, context: "Codex", respond: { _ in })
              }
            }
          },
        ]),
      .component(
        .decisions, "dock", "Decision Dock",
        summary: "Requests docked above the composer, compact and expanded.",
        systemImage: "rectangle.bottomthird.inset.filled", canvas: .fixed(width: 660, height: 620),
        keywords: ["dock", "queue", "pending"],
        states: [
          dock("one", "One request", decisions: [PreviewData.singleEdit], expanded: false),
          dock(
            "compact", "Several, compact", decisions: PreviewData.dockDecisions, expanded: false),
          dock(
            "expanded", "Several, expanded", decisions: PreviewData.dockDecisions, expanded: true),
        ]),
      .component(
        .decisions, "sheet", "Decision Sheet",
        summary: "The iPhone sheet a substantial request opens from the dock.",
        systemImage: "rectangle.portrait.bottomhalf.inset.filled",
        canvas: .fixed(width: 390, height: 760), keywords: ["iphone", "sheet"],
        states: [
          sheet("list", "Request list", path: []),
          sheet("form", "Form request", path: [PreviewData.form.id]),
          sheet("command", "Command request", path: [PreviewData.codexCommand.id]),
        ]),
      .component(
        .decisions, "summary-row", "Summary Row",
        summary: "One request in one line, answerable in place when the payload fits.",
        systemImage: "text.line.first.and.arrowtriangle.forward", canvas: .column(width: 640),
        keywords: ["row", "review"],
        states: [
          CatalogState("answerable", "Answerable") { SummaryRowSample(showsActions: true) },
          CatalogState("review", "Review only") { SummaryRowSample(showsActions: false) },
        ]),
    ]
  }

  static let kinds: [CatalogSampleItem<DecisionCard>] = [
    CatalogSampleItem("codex-command", "Codex command", PreviewData.codexCommand),
    CatalogSampleItem("approval", "File edits", PreviewData.approval),
    CatalogSampleItem("claude-tool", "Claude tool", PreviewData.claudeBash),
    CatalogSampleItem("single-edit", "Single edit", PreviewData.singleEdit),
    CatalogSampleItem("antigravity", "Antigravity", PreviewData.antigravity),
    CatalogSampleItem("plan", "Plan review", PreviewData.planReview),
    CatalogSampleItem("choice", "Choice", PreviewData.choice),
    CatalogSampleItem("form", "Form", PreviewData.form),
    CatalogSampleItem("unsupported", "Unsupported", PreviewData.unsupported),
  ]

  private static func dock(
    _ id: String, _ title: String, decisions: [DecisionCard], expanded: Bool
  ) -> CatalogState {
    CatalogState(id, title) {
      DockSample(decisions: decisions).environment(\.decisionDockStartsExpanded, expanded)
    }
  }

  private static func sheet(_ id: String, _ title: String, path: [String]) -> CatalogState {
    CatalogState(id, title) {
      DecisionSheet(
        state: DecisionSamples.conversation(PreviewData.dockDecisions),
        actions: GalleryActions.conversation, path: .constant(path), close: {})
    }
  }
}

enum DecisionSamples {
  static var feedbackDraft: FormDraft {
    var draft = FormDraft()
    draft.feedback = "Run only the auth tests, without cleaning."
    draft.isComposingFeedback = true
    return draft
  }

  /// The sample conversation waiting on `decisions`.
  static func conversation(_ decisions: [DecisionCard]) -> ConversationViewState {
    var state = PreviewData.shellConversation
    state.header.status = .needsResponse
    state.decisions = decisions
    return state
  }

  static var composer: ComposerViewState {
    var composer = PreviewData.idleSessionComposer
    composer.placeholder = "Respond to the pending request above to continue"
    return composer
  }
}

/// A card with its own draft, so the reply field and form fields can be typed into.
private struct DecisionSample: View {
  let card: DecisionCard
  var phase: DecisionPhase = .pending
  var isReadOnly = false
  @State private var draft: FormDraft

  init(
    card: DecisionCard, phase: DecisionPhase = .pending, isReadOnly: Bool = false,
    draft: FormDraft = FormDraft()
  ) {
    self.card = card
    self.phase = phase
    self.isReadOnly = isReadOnly
    _draft = State(initialValue: draft)
  }

  var body: some View {
    CatalogStack {
      DecisionCardView(
        card: card, phase: phase, isReadOnly: isReadOnly,
        context: card.permissions.command == nil ? "Claude Code" : "Codex",
        respond: isReadOnly ? nil : { _ in }, validate: { PreviewData.validate(card, $0) },
        draft: $draft)
    }
  }
}

private struct DockSample: View {
  let decisions: [DecisionCard]
  @State private var draft = ""

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      DecisionDock(
        state: DecisionSamples.conversation(decisions), actions: GalleryActions.conversation)
      ComposerView(draft: $draft, state: DecisionSamples.composer, actions: GalleryActions.composer)
    }
    .themeCanvas()
  }
}

private struct SummaryRowSample: View {
  let showsActions: Bool

  var body: some View {
    CatalogStack(spacing: Theme.Spacing.small) {
      ForEach(PreviewData.dockDecisions) { card in
        DecisionSummaryRow(
          card: card, phase: .pending, context: "Codex · Auth refresh", canRespond: true,
          showsActions: showsActions, act: { _ in }, open: {})
      }
    }
  }
}
