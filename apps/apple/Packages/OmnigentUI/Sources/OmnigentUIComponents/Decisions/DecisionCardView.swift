public import SwiftUI

/// One decision card: approvals (with Codex, Antigravity and Claude permission variants), plan
/// review, single choices, typed forms, and requests the app cannot answer. Choices that change
/// standing permissions ask for confirmation first.
public struct DecisionCardView: View {
  private let card: DecisionCard
  private let phase: DecisionPhase
  private let isReadOnly: Bool
  private let respond: ((DecisionResponse) -> Void)?
  private let validate: (([String: ElicitationValue]) -> String?)?
  private let externalDraft: Binding<FormDraft>?
  @State private var localDraft = FormDraft()

  @State private var pendingPermission: DecisionResponse?
  @Environment(\.openURL) private var openURL

  /// Creates a card.
  /// - Parameters:
  ///   - card: The card.
  ///   - phase: Where it stands.
  ///   - isReadOnly: The caller cannot respond.
  ///   - respond: Sends a response; `nil` shows the card read-only.
  ///   - validate: The core's form validator; returns a readable problem.
  public init(
    card: DecisionCard, phase: DecisionPhase = .pending, isReadOnly: Bool = false,
    respond: ((DecisionResponse) -> Void)?,
    validate: (([String: ElicitationValue]) -> String?)? = nil
  ) {
    self.init(
      card: card, phase: phase, isReadOnly: isReadOnly, respond: respond, validate: validate,
      draft: nil)
  }

  init(
    card: DecisionCard, phase: DecisionPhase, isReadOnly: Bool,
    respond: ((DecisionResponse) -> Void)?,
    validate: (([String: ElicitationValue]) -> String?)?, draft: Binding<FormDraft>?
  ) {
    self.card = card
    self.phase = phase
    self.isReadOnly = isReadOnly
    self.respond = respond
    self.validate = validate
    externalDraft = draft
  }

  private var draft: Binding<FormDraft> { externalDraft ?? $localDraft }

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
    VStack(alignment: .leading, spacing: 12) {
      header
      if !card.detail.isEmpty, card.permissions.plan == nil {
        Text(card.detail)
          .font(.callout)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .lineLimit(12)
      }
      PermissionContextView(permissions: card.permissions)
      if !isAnswered { controls }
      DecisionFooter(
        card: card, phase: phase, isReadOnly: isReadOnly || respond == nil)
    }
    .padding(14)
    .cardSurface(cornerRadius: Theme.Radius.large, stroke: accent.opacity(0.4))
    .confirmationDialog(
      "Change approval behavior?",
      isPresented: Binding(
        get: { pendingPermission != nil }, set: { if !$0 { pendingPermission = nil } }),
      presenting: pendingPermission
    ) { response in
      Button("Approve and Apply") { send(response) }
      Button("Cancel", role: .cancel) { pendingPermission = nil }
    } message: { _ in
      Text(
        "This can let future actions run without asking. The change applies on the server, not just on this device."
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(card.title). \(card.detail)")
    .accessibilityIdentifier("decision-\(card.id)")
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: headerSymbol)
        .font(.body.weight(.semibold))
        .foregroundStyle(iconTint)
        .frame(width: 28, height: 28)
        .background(iconTint.opacity(0.15), in: Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(displayTitle).font(.headline)
        if let policy = card.policyName ?? card.phase {
          Text(policy).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      if card.isMirrored { Pill(text: "From a subagent", systemImage: "arrow.triangle.branch") }
    }
  }

  private var headerSymbol: String {
    if case .answered = phase { return "checkmark" }
    if card.permissions.plan != nil { return "list.bullet.clipboard" }
    switch card.kind {
    case .approval: return "hand.raised.fill"
    case .choice, .form: return "questionmark.bubble.fill"
    case .unsupported: return "safari"
    }
  }

  @ViewBuilder private var controls: some View {
    switch card.kind {
    case .approval:
      if card.permissions.plan != nil {
        PlanReviewControls(
          card: card, canRespond: canRespond, send: send(_:),
          confirm: { pendingPermission = $0 })
      } else {
        approvalControls
      }
    case .choice(_, let options):
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
          Button {
            send(.answer(value: option))
          } label: {
            Text(option)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.bordered)
          .controlSize(.large)
          .disabled(!canRespond)
          .accessibilityIdentifier("decision-option-\(card.id)-\(index)")
        }
        dismissButton
      }
    case .form(let fields):
      formControls(fields)
    case .unsupported(let reason, let externalURL):
      VStack(alignment: .leading, spacing: 8) {
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
          .buttonStyle(.borderedProminent)
          Text(url.host() ?? address).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var approvalControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { primaryApprovalButtons }
        VStack(alignment: .leading, spacing: 8) { primaryApprovalButtons }
      }
      let extras = permissionResponses
      if !extras.isEmpty {
        FlowLayout(spacing: 6) {
          ForEach(extras, id: \.response) { extra in
            Button {
              pendingPermission = extra.response
            } label: {
              Label(extra.label, systemImage: extra.systemImage)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .disabled(!canRespond)
            .accessibilityHint("Asks for confirmation; changes approval behavior")
          }
        }
      }
    }
  }

  @ViewBuilder private var primaryApprovalButtons: some View {
    Button {
      send(.approve)
    } label: {
      Text("Approve").frame(minWidth: 80)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .disabled(!canRespond)
    .accessibilityIdentifier("approval-approve-\(card.id)")
    Button {
      send(.decline)
    } label: {
      Text("Reject").frame(minWidth: 80)
    }
    .buttonStyle(.bordered)
    .tint(.primary)
    .controlSize(.large)
    .disabled(!canRespond)
    .accessibilityIdentifier("approval-decline-\(card.id)")
  }

  private var permissionResponses: [PermissionChoice] {
    PermissionChoice.choices(for: card.permissions)
  }

  private func formControls(_ fields: [FormField]) -> some View {
    let values = draft.wrappedValue.values(for: fields)
    let problem = draft.wrappedValue.localProblem(for: fields) ?? validate?(values)
    return VStack(alignment: .leading, spacing: 12) {
      DecisionFormFields(fields: fields, draft: draft, cardID: card.id)
        .disabled(!canRespond)
      if let problem {
        Label(problem, systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("decision-form-validation-\(card.id)")
      }
      HStack(spacing: 8) {
        Button("Submit") { send(.form(values: values)) }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(!canRespond || problem != nil)
          .accessibilityIdentifier("decision-form-submit-\(card.id)")
        dismissButton
      }
    }
  }

  private var dismissButton: some View {
    Button("Cancel") { send(.cancel) }
      .buttonStyle(.borderless)
      .font(.callout)
      .disabled(!canRespond)
  }

  private func send(_ response: DecisionResponse) {
    pendingPermission = nil
    guard canRespond, let respond else { return }
    respond(response)
  }
}

extension DecisionCardView {
  /// The web's card titles.
  private var displayTitle: String {
    if card.permissions.plan != nil { return "Plan review" }
    if card.permissions.command != nil { return "Command approval" }
    switch card.kind {
    case .approval: return "Approval required"
    case .choice: return "Choose an option"
    case .form: return card.title == "Response requested" ? "Questions" : card.title
    case .unsupported: return card.title
    }
  }

  private var iconTint: ThemeColor {
    switch phase {
    case .answered: Theme.success
    case .failed: Theme.failure
    case .pending, .resolving: .approval
    }
  }

  private var accent: ThemeColor {
    switch phase {
    case .answered: Theme.success
    case .failed: Theme.failure
    case .pending, .resolving: Theme.attention
    }
  }
}
