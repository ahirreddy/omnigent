import Foundation
import SwiftUI

extension PreviewData {
  /// A Claude tool approval with the tool input as its payload; a decline can carry a reply.
  static let claudeBash = card(
    "elic_bash",
    detail: """
      Claude wants to call **Bash**

      Bash({"command": "rm -rf .build && swift test --parallel", "description": "Clean build, then run the tests"})
      """,
    permissions: PermissionOptions(rememberLabel: "Bash"), acceptsFeedback: true)

  /// A single-file edit, simple enough to answer from the dock's compact row.
  static let singleEdit = card(
    "elic_edit", detail: "Claude wants to edit one file.",
    permissions: PermissionOptions(
      allowAllEdits: true,
      files: [
        DecisionFileChange(
          path: "apps/apple/Packages/OmnigentUI/README.md", added: 4, removed: 1, kind: .modify)
      ]),
    acceptsFeedback: true)

  /// A Claude edit deep in the tree with long lines: basename first, 13 pt wrapped code and the
  /// full-screen review on a phone.
  static let longEdit = card(
    "elic_long_edit",
    detail: #"""
      Claude wants to call **Edit**

      Edit({"file_path": "apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/SessionList/SessionRow.swift", "old_string": "      Text(session.title).font(.body).lineLimit(1)\n      ProgressView().controlSize(.mini)\n      Spacer()", "new_string": "      Text(session.title).font(Theme.Typography.label).lineLimit(1).truncationMode(.middle)\n      if session.status == .running { RunningDot(isAnimating: isWindowActive) }\n      Spacer(minLength: Theme.Spacing.small)\n      NeedsYouCapsule(count: session.pendingDecisions)"})
      """#,
    permissions: PermissionOptions(rememberLabel: "Edit"), acceptsFeedback: true)

  /// The requests the decision playground and the dock captures use, in arrival order.
  static let dockDecisions = [codexCommand, approval, claudeBash, choice, planReview, form]
}

/// The decisions playground: v2 cards, the dock compact and expanded, and the iPhone layout.
/// `OMNIGENT_PLAYGROUND_DECISIONS=cards|dock|phone` picks the first page.
struct DecisionPlayground: View {
  enum Page: String, CaseIterable, Identifiable {
    case cards
    case dock
    case phone

    var id: Self { self }

    var title: String {
      switch self {
      case .cards: "Cards"
      case .dock: "Dock"
      case .phone: "iPhone"
      }
    }
  }

  @State private var page =
    ProcessInfo.processInfo.environment["OMNIGENT_PLAYGROUND_DECISIONS"].flatMap(Page.init)
    ?? .cards
  @State private var conversation = Self.conversation
  @State private var draft = ""
  @State private var drafts = Self.seededDrafts()

  /// The Claude tool card starts with "Tell the agent instead" open and a reply typed.
  private static func seededDrafts() -> DecisionDrafts {
    let drafts = DecisionDrafts()
    var draft = FormDraft()
    draft.feedback = "Run only the auth tests, without cleaning."
    draft.isComposingFeedback = true
    drafts.drafts["cards-\(PreviewData.claudeBash.id)"] = draft
    return drafts
  }

  private static var conversation: ConversationViewState {
    var state = PreviewData.shellConversation
    state.header.status = .needsResponse
    state.decisions = PreviewData.dockDecisions
    return state
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("Page", selection: $page) {
        ForEach(Page.allCases) { page in Text(page.title).tag(page) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .padding(Theme.Spacing.medium)
      .accessibilityIdentifier("decision-playground-page")
      Divider()
      switch page {
      case .cards: cards
      case .dock: dock
      case .phone: phone
      }
    }
    .themeCanvas()
    .environment(drafts)
  }

  private var actions: ConversationActions {
    ConversationActions(
      respond: { card, response in
        conversation.decisionPhases[card.id] = .answered(summary: response.summary)
        conversation.revision += 1
      },
      validateForm: PreviewData.validate)
  }

  // MARK: Cards

  private var cards: some View {
    ScrollView {
      HStack(alignment: .top, spacing: Theme.Spacing.extraLarge) {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
          card(PreviewData.codexCommand)
          card(PreviewData.approval)
          card(PreviewData.claudeBash)
          card(PreviewData.antigravity)
        }
        .frame(width: 560)
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
          card(PreviewData.planReview)
          card(PreviewData.choice)
          card(
            PreviewData.singleEdit, key: "failed",
            phase: .failed(message: "The host is offline. Reconnect and try again."))
          card(PreviewData.codexCommand, key: "answered", phase: .answered(summary: "Approved"))
          DecisionCardView(card: PreviewData.claudeBash, style: .compact, respond: { _ in })
          DecisionCardView(card: PreviewData.codexCommand, style: .compact, respond: { _ in })
        }
        .frame(width: 560)
      }
      .padding(Theme.Spacing.extraLarge)
      .frame(maxWidth: .infinity)
    }
  }

  private func card(
    _ card: DecisionCard, key: String = "", phase: DecisionPhase = .pending
  ) -> some View {
    DecisionCardView(
      card: card, phase: phase, isReadOnly: false,
      context: card.permissions.command == nil ? "Claude Code" : "Codex",
      respond: { _ in }, validate: { PreviewData.validate(card, $0) },
      draft: drafts.binding("cards-\(card.id)\(key)")
    )
    .decisionApproveShortcut(card.id == PreviewData.codexCommand.id ? card.id : nil)
  }

  // MARK: Dock

  private var dock: some View {
    HStack(alignment: .bottom, spacing: Theme.Spacing.extraLarge) {
      dockColumn("Compact", expanded: false)
      dockColumn("Expanded", expanded: true)
    }
    .padding(Theme.Spacing.extraLarge)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
  }

  private func dockColumn(_ title: String, expanded: Bool) -> some View {
    VStack(spacing: 0) {
      Text(title).font(.headline).foregroundStyle(.secondary).padding(.bottom, Theme.Spacing.small)
      Spacer(minLength: 0)
      DecisionDock(state: conversation, actions: actions)
        .environment(\.decisionDockStartsExpanded, expanded)
      ComposerView(
        draft: $draft, state: Self.composer, actions: ComposerActions(send: {}))
    }
    .frame(width: 620)
  }

  private static var composer: ComposerViewState {
    var composer = PreviewData.idleSessionComposer
    composer.placeholder = "Respond to the pending request above to continue"
    return composer
  }

  // MARK: Phone

  private var phone: some View {
    HStack(spacing: Theme.Spacing.extraLarge) {
      phoneFrame {
        NavigationStack {
          ConversationScreen(
            state: conversation, composer: Self.composer, draft: $draft,
            showsInspector: .constant(false), actions: actions,
            composerActions: ComposerActions(send: {}))
        }
      }
      phoneFrame {
        DecisionReviewScreen(
          card: PreviewData.longEdit, phase: .pending, isReadOnly: false, context: "Claude Code",
          respond: { _ in }, validate: nil, draft: drafts.binding("review"), close: {})
      }
      phoneFrame {
        // The sheet a substantial request opens, shown in place for review.
        DecisionSheet(
          state: conversation, actions: actions, path: .constant([PreviewData.form.id]),
          close: {})
      }
    }
    .padding(Theme.Spacing.extraLarge)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background.secondary)
  }

  private func phoneFrame(@ViewBuilder content: () -> some View) -> some View {
    content()
      .layoutWidth(.compact)
      .environment(\.horizontalSizeClass, .compact)
      .frame(width: 390)
      .frame(maxHeight: 820)
      .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 36, style: .continuous).strokeBorder(
          .separator, lineWidth: 2)
      }
  }
}
