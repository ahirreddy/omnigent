import SwiftUI

/// The context an approval card shows: the Codex command, Antigravity's action and pattern,
/// the plan under review, and the offered directories.
struct PermissionContextView: View {
  let permissions: PermissionOptions

  var body: some View {
    if let command = permissions.command {
      VStack(alignment: .leading, spacing: 6) {
        CodeBlockView(code: "$ \(command.command)", language: "command", maxLines: 8)
        if let cwd = command.cwd {
          LabeledContent("Directory") { Text(cwd).font(Theme.codeFont).textSelection(.enabled) }
            .font(.caption)
        }
        if let reason = command.reason {
          LabeledContent("Reason") { Text(reason).textSelection(.enabled) }
            .font(.caption)
        }
      }
    }
    if let agy = permissions.antigravity {
      VStack(alignment: .leading, spacing: 6) {
        if let action = agy.actionDescription {
          Text(action).font(.callout).textSelection(.enabled)
        }
        if let pattern = agy.alwaysAllowPattern {
          LabeledContent("Always-allow pattern") {
            Text(pattern).font(Theme.codeFont).textSelection(.enabled)
          }
          .font(.caption)
        }
      }
    }
    if let plan = permissions.plan {
      BoundedScrollView(maxHeight: 320) {
        MarkdownView(plan)
          .padding(12)
      }
      .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
      .accessibilityLabel("Proposed plan")
    }
    if !permissions.permissionDirectories.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        Text("Directories offered for this session").font(.caption).foregroundStyle(.secondary)
        ForEach(permissions.permissionDirectories, id: \.self) { directory in
          Text(directory).font(Theme.codeFont).textSelection(.enabled)
        }
      }
    }
  }
}

/// An approval variant that changes standing permissions; each one is confirmed first.
struct PermissionChoice {
  let response: DecisionResponse
  let label: String
  let systemImage: String

  static func choices(for permissions: PermissionOptions) -> [Self] {
    var choices: [Self] = []
    if permissions.allowAllEdits {
      choices.append(
        .init(
          response: .approveAllEdits, label: "Accept & allow all edits",
          systemImage: "pencil.and.list.clipboard"))
    }
    if permissions.allowAutoMode {
      choices.append(
        .init(
          response: .approveAutoMode, label: "Approve & switch to auto mode", systemImage: "bolt")
      )
    }
    if !permissions.permissionDirectories.isEmpty {
      choices.append(
        .init(
          response: .approveDirectories, label: "Approve & allow directories for this session",
          systemImage: "folder.badge.plus"))
    }
    if let label = permissions.rememberLabel {
      choices.append(
        .init(
          response: .approveRemembering, label: "Approve & don't ask again for \(label)",
          systemImage: "checkmark.seal"))
    }
    if let policy = permissions.execPolicyAmendment, !policy.isEmpty {
      choices.append(
        .init(
          response: .approveCommandPolicy(policy: policy),
          label: "Approve and remember", systemImage: "terminal"))
    }
    if permissions.offersPersist(.session) {
      choices.append(
        .init(
          response: .approvePersist(mode: .session), label: "Approve for this session",
          systemImage: "clock"))
    }
    if permissions.offersPersist(.always) {
      choices.append(
        .init(
          response: .approvePersist(mode: .always), label: "Always allow", systemImage: "infinity"
        ))
    }
    return choices
  }
}

/// Plan review: approve (optionally changing the session's mode, confirmed first), decline, or
/// reject with feedback for a revised plan.
struct PlanReviewControls: View {
  let card: DecisionCard
  let canRespond: Bool
  let send: (DecisionResponse) -> Void
  let confirm: (DecisionResponse) -> Void
  @State private var feedback = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { planButtons }
        VStack(alignment: .leading, spacing: 8) { planButtons }
      }
      HStack(alignment: .bottom, spacing: 8) {
        TextField("What should change about the plan? (optional)", text: $feedback, axis: .vertical)
          .lineLimit(1...4)
          .textFieldStyle(.roundedBorder)
          .disabled(!canRespond)
          .accessibilityIdentifier("decision-plan-feedback-\(card.id)")
        Button("Reject plan") {
          let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
          send(text.isEmpty ? .decline : .declineWithFeedback(feedback: text))
        }
        .disabled(!canRespond)
        .accessibilityIdentifier("decision-plan-reject-\(card.id)")
      }
    }
  }

  @ViewBuilder private var planButtons: some View {
    Button("Yes, manually approve edits") { send(.approve) }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(!canRespond)
    if card.permissions.allowAllEdits {
      Button("Accept & allow all edits") { confirm(.approveAllEdits) }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!canRespond)
    }
    if card.permissions.allowAutoMode {
      Button("Yes, and use auto mode") { confirm(.approveAutoMode) }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!canRespond)
    }
    Button("Reject") { send(.decline) }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .disabled(!canRespond)
  }
}

/// The card's status line: read-only, sending, answered or failed.
struct DecisionFooter: View {
  let card: DecisionCard
  let phase: DecisionPhase
  let isReadOnly: Bool

  var body: some View {
    switch phase {
    case .pending:
      if isReadOnly {
        Label("Read-only access cannot respond to this request.", systemImage: "eye")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("decision-read-only-\(card.id)")
      }
    case .resolving:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Sending your response").font(.caption).foregroundStyle(.secondary)
      }
    case .answered(let summary):
      Label("\(summary). Waiting for the server to confirm.", systemImage: "checkmark.circle.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.running)
        .accessibilityIdentifier("decision-status-\(card.id)")
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(Theme.failure)
        .textSelection(.enabled)
        .accessibilityIdentifier("decision-error-\(card.id)")
    }
  }
}
