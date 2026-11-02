public import SwiftUI

/// How a ``DecisionCardView`` lays out.
public enum DecisionCardStyle: Hashable, Sendable {
  /// The whole card: payload first, then the actions.
  case full
  /// One line ("Run `cargo test`", "Edit 3 files") with inline Approve and Reject (or the
  /// answers) when the payload fits there; "Review" expands it to the full card in place.
  case compact
}

/// One decision card: approvals (with the Codex, Antigravity and Claude permission variants),
/// plan review, single choices, typed forms, and requests the app cannot answer.
///
/// Payload first, then one pink primary action. Approvals offer Approve, Reject, "Tell the agent
/// instead" (when the card can carry a reply) and "More approval options…"; every choice that
/// changes standing permissions asks "Change approval behavior?" first. An answered card
/// collapses to one line.
///
/// Use `.compact` to resolve in place from a list (the Inbox); `.decisionApproveShortcut(_:)`
/// gives one card's Approve the Command-Return shortcut.
public struct DecisionCardView: View {
  private let card: DecisionCard
  private let phase: DecisionPhase
  private let isReadOnly: Bool
  private let style: DecisionCardStyle
  private let context: String?
  private let respond: ((DecisionResponse) -> Void)?
  private let validate: (([String: ElicitationValue]) -> DecisionFormProblem?)?
  private let externalDraft: Binding<FormDraft>?
  @State private var localDraft = FormDraft()
  @State private var pendingPermission: PermissionChoice?
  @State private var isExpanded = false
  @State private var isReviewing = false
  @Environment(\.openURL) private var openURL
  @Environment(\.decisionIDPrefix) private var idPrefix
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.decisionCodeLayout) private var codeLayout

  /// Creates a card.
  /// - Parameters:
  ///   - card: The card.
  ///   - phase: Where it stands.
  ///   - isReadOnly: The caller cannot respond.
  ///   - style: Full card, or one compact row that expands in place.
  ///   - context: The agent or session, shown on the compact row ("Codex · Auth refresh").
  ///   - respond: Sends a response; `nil` shows the card read-only.
  ///   - validate: The core's form validator; returns the first problem and its field.
  public init(
    card: DecisionCard, phase: DecisionPhase = .pending, isReadOnly: Bool = false,
    style: DecisionCardStyle = .full, context: String? = nil,
    respond: ((DecisionResponse) -> Void)?,
    validate: (([String: ElicitationValue]) -> DecisionFormProblem?)? = nil
  ) {
    self.init(
      card: card, phase: phase, isReadOnly: isReadOnly, style: style, context: context,
      respond: respond, validate: validate, draft: nil)
  }

  init(
    card: DecisionCard, phase: DecisionPhase, isReadOnly: Bool,
    style: DecisionCardStyle = .full, context: String? = nil,
    respond: ((DecisionResponse) -> Void)?,
    validate: (([String: ElicitationValue]) -> DecisionFormProblem?)?,
    draft: Binding<FormDraft>?
  ) {
    self.card = card
    self.phase = phase
    self.isReadOnly = isReadOnly
    self.style = style
    self.context = context
    self.respond = respond
    self.validate = validate
    externalDraft = draft
  }

  private var draft: Binding<FormDraft> { externalDraft ?? $localDraft }
  private var availability: DecisionAvailability { DecisionAvailability(card) }

  private var isAnswered: Bool {
    if case .answered = phase { return true }
    return false
  }

  private var canRespond: Bool {
    guard respond != nil, !isReadOnly else { return false }
    switch phase {
    case .pending, .failed: return true
    case .resolving, .answered: return false
    }
  }

  /// The card.
  public var body: some View {
    Group {
      if style == .compact, !isExpanded {
        DecisionSummaryRow(
          card: card, phase: phase, context: context, canRespond: canRespond,
          showsActions: true, act: act(_:), open: { isExpanded = true }
        )
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .cardSurface(cornerRadius: Theme.Radius.large)
      } else if isAnswered {
        answeredLine
      } else {
        fullCard
      }
    }
    .confirmationDialog(
      "Change approval behavior?",
      isPresented: Binding(
        get: { pendingPermission != nil }, set: { if !$0 { pendingPermission = nil } }),
      presenting: pendingPermission
    ) { choice in
      Button("Approve and Apply") { send(choice.response) }
        .accessibilityIdentifier("\(idPrefix)approval-confirm-\(card.id)")
      Button("Cancel", role: .cancel) { pendingPermission = nil }
    } message: { choice in
      Text(
        "\(choice.label). Future actions in this scope can run without asking. The change applies on the server, not just on this device."
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(displayTitle). \(DecisionSummary(card).plain)")
    .accessibilityIdentifier("\(idPrefix)decision-\(card.id)")
    #if os(iOS)
      .fullScreenCover(isPresented: $isReviewing) { review }
    #else
      .sheet(isPresented: $isReviewing) { review.frame(minWidth: 480, minHeight: 560) }
    #endif
  }

  private var fullCard: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      header
      DecisionPayloadView(card: card)
      controls
      DecisionFooter(card: card, phase: phase, isReadOnly: isReadOnly || respond == nil)
    }
    .padding(Theme.Spacing.card)
    .cardSurface(cornerRadius: Theme.Radius.large)
  }

  /// "✓ Approved · Run cargo test", waiting for the server to retire the card.
  private var answeredLine: some View {
    HStack(spacing: Theme.Spacing.small) {
      DecisionStateGlyph(card: card, phase: phase)
      if case .answered(let summary) = phase {
        Text("\(summary) \u{00B7} \(DecisionSummary(card).plain)")
          .font(.callout)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: Theme.Spacing.small)
      Text("Waiting for the server")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, Theme.Spacing.card)
    .padding(.vertical, Theme.Spacing.medium)
    .cardSurface(cornerRadius: Theme.Radius.large)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("\(idPrefix)decision-status-\(card.id)")
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
      DecisionStateGlyph(card: card, phase: phase)
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        Text(displayTitle).font(.headline)
        if let subtitle {
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: Theme.Spacing.small)
      if card.isMirrored { Pill(text: "From a subagent", systemImage: "arrow.triangle.branch") }
      if offersFullScreenReview {
        Button("Review full screen", systemImage: "arrow.up.left.and.arrow.down.right") {
          isReviewing = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .tint(.primary)
        .help("Review full screen")
        .accessibilityIdentifier("\(idPrefix)decision-review-full-\(card.id)")
      }
      if style == .compact {
        Button("Collapse", systemImage: "chevron.up") { isExpanded = false }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("\(idPrefix)decision-collapse-\(card.id)")
      }
    }
  }

  /// Who is asking: the agent or session the host passed, else the policy name.
  private var subtitle: String? {
    [context, card.policyName].compactMap(\.self).first { !$0.isEmpty }
  }

  @ViewBuilder private var controls: some View {
    let availability = availability
    switch card.kind {
    case .approval:
      ApprovalControls(
        card: card, availability: availability, canRespond: canRespond, draft: draft,
        act: act(_:))
    case .choice(_, let options):
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
          Button {
            act(.answer(value: option))
          } label: {
            Text(option)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.bordered)
          .tint(.primary)
          .controlSize(.large)
          .disabled(!canRespond)
          .accessibilityIdentifier("\(idPrefix)decision-option-\(card.id)-\(index)")
        }
        dismissButton
      }
    case .form(let fields):
      formControls(fields)
    case .unsupported(let reason, let externalURL):
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Label(reason, systemImage: "info.circle")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let address = externalURL, let url = MarkdownParser.safeURL(address) {
          Button {
            openURL(url)
          } label: {
            Label("Open approval page", systemImage: "arrow.up.forward.app")
          }
          // A link out, not the screen's primary action.
          .buttonStyle(.bordered)
          .tint(.primary)
          .accessibilityIdentifier("\(idPrefix)decision-open-page-\(card.id)")
          Text(url.host() ?? address).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  /// Widening choices go through the confirmation; everything else is sent.
  private func act(_ response: DecisionResponse) {
    switch DecisionRoute(response) {
    case .send(let response):
      send(response)
    case .confirm(let response):
      pendingPermission =
        PermissionChoice.choices(for: card).first { $0.response == response }
        ?? PermissionChoice(
          response: response, label: response.summary, systemImage: "exclamationmark.shield")
    }
  }

  private func send(_ response: DecisionResponse) {
    pendingPermission = nil
    guard canRespond, let respond else { return }
    if case .declineWithFeedback = response {
      draft.wrappedValue.isComposingFeedback = false
    }
    respond(response)
  }
}

extension DecisionCardView {
  /// On a phone a large payload opens in a full-screen review with the same actions.
  private var offersFullScreenReview: Bool {
    layoutWidth == .compact && style == .full && !codeLayout.isFullScreen && !isAnswered
      && DecisionPayloadSize.isLarge(card)
  }

  private var review: some View {
    DecisionReviewScreen(
      card: card, phase: phase, isReadOnly: isReadOnly, context: context,
      respond: respond.map { respond in
        { response in
          isReviewing = false
          respond(response)
        }
      },
      validate: validate, draft: draft, close: { isReviewing = false })
  }

  private func formControls(_ fields: [FormField]) -> some View {
    let values = draft.wrappedValue.values(for: fields)
    let local = draft.wrappedValue.localProblem(for: fields)
    let validator = local == nil ? validate?(values) : nil
    let problem = local ?? validator?.message
    // Field problems show under their field; only one that names no field stays here. Local
    // problems always belong to a field.
    let validatorField = validator?.field(in: fields)
    let field =
      local == nil
      ? validatorField : fields.first { draft.wrappedValue.problem(for: $0) != nil }
    let canSubmit = canRespond && problem == nil
    return VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      DecisionFormFields(
        fields: fields, draft: draft, cardID: card.id,
        validatorProblem: validatorField.flatMap { field in
          validator.map { (key: field.key, message: $0.message) }
        }
      )
      .disabled(!canRespond)
      if let problem, field == nil {
        Label(problem, systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("\(idPrefix)decision-form-validation-\(card.id)")
      }
      HStack(spacing: Theme.Spacing.small) {
        Button("Submit") { act(.form(values: values)) }
          .buttonStyle(.borderedProminent)
          // Disabled reads neutral: a faded accent still looks like an action.
          .tint(canSubmit ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary))
          .controlSize(.large)
          .disabled(!canSubmit)
          .accessibilityIdentifier("\(idPrefix)decision-form-submit-\(card.id)")
        dismissButton
      }
    }
  }

  private var dismissButton: some View {
    Button("Cancel") { act(.cancel) }
      .buttonStyle(.borderless)
      .tint(.secondary)
      .font(.callout)
      .disabled(!canRespond)
      .accessibilityIdentifier("\(idPrefix)decision-cancel-\(card.id)")
  }
}

extension DecisionCardView {
  /// The web's card titles.
  private var displayTitle: String {
    if card.permissions.plan != nil { return "Plan review" }
    if card.permissions.command != nil { return "Command approval" }
    switch card.kind {
    case .approval: return DecisionSummary.isGeneric(card.title) ? "Approval required" : card.title
    case .choice: return "Choose an option"
    case .form: return DecisionSummary.isGeneric(card.title) ? "Questions" : card.title
    case .unsupported: return card.title
    }
  }
}
