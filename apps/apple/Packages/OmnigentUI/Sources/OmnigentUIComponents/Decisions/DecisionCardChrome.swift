import SwiftUI

/// The primary action: pink, and on the Mac labelled with Command-Return when it owns the
/// shortcut.
struct ApproveButton: View {
  let title: String
  let cardID: String
  let isEnabled: Bool
  let ownsShortcut: Bool
  let identifier: String
  var controlSize: ControlSize = .large
  /// Pink. A list of rows keeps pink for the one request that owns the shortcut.
  let isProminent: Bool
  let action: () -> Void

  var body: some View {
    if isProminent {
      button.buttonStyle(.borderedProminent).tint(Theme.accent)
    } else {
      button.buttonStyle(.bordered).tint(.primary)
    }
  }

  private var button: some View {
    Button(action: action) {
      HStack(spacing: Theme.Spacing.small) {
        Text(title)
        #if os(macOS)
          if ownsShortcut {
            Text(verbatim: "\u{2318}\u{21A9}")
              .font(.caption.weight(.medium))
              .opacity(0.75)
              .accessibilityHidden(true)
          }
        #endif
      }
      .frame(minWidth: 64)
    }
    .controlSize(controlSize)
    .keyboardShortcut(ownsShortcut ? KeyboardShortcut(.return, modifiers: .command) : nil)
    .disabled(!isEnabled)
    .help(ownsShortcut ? "\(title) (Command-Return)" : title)
    .accessibilityIdentifier(identifier)
  }
}

/// The card's status line: read-only, sending, answered or failed.
struct DecisionFooter: View {
  let card: DecisionCard
  let phase: DecisionPhase
  let isReadOnly: Bool
  @Environment(\.decisionIDPrefix) private var idPrefix

  var body: some View {
    switch phase {
    case .pending:
      if isReadOnly {
        Label("Read-only access cannot respond to this request.", systemImage: "eye")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("\(idPrefix)decision-read-only-\(card.id)")
      }
    case .resolving:
      HStack(spacing: Theme.Spacing.small) {
        ProgressView().controlSize(.small)
        Text("Sending your response").font(.caption).foregroundStyle(.secondary)
      }
    case .answered(let summary):
      Label("\(summary). Waiting for the server to confirm.", systemImage: "checkmark.circle.fill")
        .font(Theme.Typography.section)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("\(idPrefix)decision-status-\(card.id)")
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(Theme.failure)
        .textSelection(.enabled)
        .accessibilityIdentifier("\(idPrefix)decision-error-\(card.id)")
    }
  }
}

/// The small state accent: amber while the card waits, green once answered, red on failure.
struct DecisionStateGlyph: View {
  let card: DecisionCard
  let phase: DecisionPhase

  var body: some View {
    Image(systemName: symbol)
      .font(.callout.weight(.semibold))
      .foregroundStyle(tint)
      .frame(width: 18)
      .accessibilityHidden(true)
  }

  private var symbol: String {
    switch phase {
    case .answered: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .pending, .resolving: break
    }
    if card.permissions.plan != nil { return "list.bullet.clipboard" }
    if card.permissions.command != nil { return "terminal" }
    if !card.permissions.files.isEmpty { return "pencil" }
    switch card.kind {
    case .approval: return "hand.raised.fill"
    case .choice, .form: return "questionmark.bubble.fill"
    case .unsupported: return "safari"
    }
  }

  private var tint: ThemeColor {
    switch phase {
    case .answered: Theme.success
    case .failed: Theme.failure
    case .pending, .resolving: .approval
    }
  }
}
