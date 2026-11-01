import SwiftUI

/// What Send does in the composer's current state, and why it cannot.
struct ComposerSendRules {
  let state: ComposerViewState
  let draft: String
  /// The host keeps a queue.
  let canQueue: Bool
  /// Touch has no Escape key to mention.
  var layout: ComposerLayoutStyle = .platformDefault

  /// What Send does now.
  var intent: ComposerSendIntent {
    ComposerSendIntent.resolve(
      isRunning: state.isRunning, canSteer: state.canSteer, hasQueue: !state.queue.isEmpty,
      canQueue: canQueue)
  }

  /// The other choice while the agent works (⌥⌘Return and the Send button's menu).
  var alternative: ComposerSendIntent? {
    intent.alternative(canSteer: state.canSteer, canQueue: canQueue)
  }

  /// Why nothing can be sent now, or `nil`.
  var sendBlockedReason: String? {
    if let reason = state.availability.reason { return reason }
    switch state.delivery {
    case .sending: return state.purpose == .start ? "Starting session" : "Sending"
    case .uncertain: return "Check the conversation before sending again."
    case .idle, .failed: break
    }
    if state.attachments.contains(where: { if case .failed = $0.state { true } else { false } }) {
      return "Remove the attachments that failed."
    }
    if state.attachments.contains(where: { if case .uploading = $0.state { true } else { false } })
    {
      return "Waiting for attachments to upload."
    }
    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, state.attachments.isEmpty {
      return state.purpose == .start ? "Enter a message to get started" : "Type a message."
    }
    return nil
  }

  /// Why `intent` cannot run now, or `nil`.
  /// - Parameter intent: The intent.
  /// - Returns: The reason.
  func blockedReason(for intent: ComposerSendIntent) -> String? {
    if let reason = sendBlockedReason { return reason }
    if intent == .queue, canQueue, !state.attachments.isEmpty {
      return "Queued messages can't carry attachments. Steer now, or send after this turn."
    }
    return nil
  }

  /// The placeholder: while the agent works, the default one says what a send does. Only the
  /// Mac mentions Esc; touch has the Stop button beside the field.
  var placeholder: String {
    let isDefault = state.placeholder == ComposerViewState().placeholder
    let touch = layout == .touch
    let idle = touch && isDefault && state.purpose == .session ? "Reply\u{2026}" : state.placeholder
    guard state.isRunning, isDefault else { return idle }
    let stop = touch ? "\u{2026}" : " \u{2014} Esc to stop"
    switch intent {
    case .steer: return "Steer the agent" + stop
    case .queue: return "Queue a follow-up" + stop
    case .send: return idle
    }
  }

  /// The Send button's accessibility label.
  func title(for intent: ComposerSendIntent) -> String {
    switch intent {
    case .send: state.purpose == .start ? "Start session" : "Send"
    case .steer: "Send now and steer"
    case .queue: canQueue ? "Queue after this turn" : "Send after this turn"
    }
  }
}

/// Stop and Send. While the agent works Stop is always there, and Send says what it will do
/// ("Send now · steer" or "Queued · after this turn"); its menu offers the other choice.
struct ComposerSendControls: View {
  let state: ComposerViewState
  let rules: ComposerSendRules
  let hasDraft: Bool
  let perform: (ComposerSendIntent) -> Void
  let interrupt: (@MainActor () -> Void)?
  @Environment(\.commandReturnOwner) private var commandReturnOwner
  @Environment(\.composerLayoutStyle) private var layout

  /// A pending request's Approve has Command-Return; Send gives it up and says so.
  private var approveOwnsCommandReturn: Bool { commandReturnOwner == .approve }

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      if state.isRunning {
        stop
      }
      if !state.isRunning || hasDraft {
        // The touch bar has no room for the words; Send's label and hint say it.
        if state.isRunning, layout == .card, let label = rules.intent.label {
          Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
            .accessibilityIdentifier("composer-send-intent")
        }
        send
      }
    }
  }

  private var stop: some View {
    Button {
      interrupt?()
    } label: {
      Group {
        if state.isStopping {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "stop.fill").font(.caption.weight(.bold))
            .accessibilityHidden(true)
        }
      }
      // Touch: a filled circle with a square, always in reach while the agent works.
      .foregroundStyle(layout == .touch ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
      .frame(width: layout.sendCircle, height: layout.sendCircle)
      .background(
        layout == .touch ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.12)),
        in: Circle()
      )
      .frame(width: layout.sendTarget, height: layout.sendTarget)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut(".", modifiers: .command)
    .disabled(interrupt == nil || state.isStopping)
    .help(layout == .touch ? "Stop" : "Stop (Esc)")
    .accessibilityLabel("Stop")
    .accessibilityHint("Stops the agent's current turn")
    .accessibilityIdentifier("composer-stop")
  }

  private var send: some View {
    let intent = rules.intent
    let blocked = rules.blockedReason(for: intent)
    return Button {
      perform(intent)
    } label: {
      Group {
        if state.delivery == .sending {
          ProgressView().controlSize(.small).tint(ThemeColor.onAccent)
        } else {
          Image(systemName: intent == .queue ? "text.append" : "arrow.up")
            .font(.body.weight(.semibold))
            .accessibilityHidden(true)
        }
      }
      .foregroundStyle(blocked == nil ? ThemeColor.onAccent : ThemeColor.secondary)
      .frame(width: layout.sendCircle, height: layout.sendCircle)
      .background(blocked == nil ? Theme.accent : ThemeColor.hover, in: Circle())
      .frame(width: layout.sendTarget, height: layout.sendTarget)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut(
      approveOwnsCommandReturn ? nil : KeyboardShortcut(.return, modifiers: .command)
    )
    .disabled(blocked != nil)
    .contextMenu {
      if let alternative = rules.alternative {
        Button(alternative.label ?? rules.title(for: alternative)) { perform(alternative) }
          .disabled(rules.blockedReason(for: alternative) != nil)
        Text("Option-Command-Return")
      }
    }
    .help(sendHelp(blocked: blocked, intent: intent))
    .accessibilityLabel(rules.title(for: intent))
    .accessibilityValue(blocked ?? "")
    .accessibilityIdentifier("composer-send")
  }

  /// The tooltip; it names the request's Approve when that owns Command-Return.
  private func sendHelp(blocked: String?, intent: ComposerSendIntent) -> String {
    let text = blocked ?? help(intent)
    return approveOwnsCommandReturn ? "\(text) Command-Return approves the request." : text
  }

  private func help(_ intent: ComposerSendIntent) -> String {
    guard let alternative = rules.alternative, let other = alternative.label else {
      return intent.label ?? rules.title(for: intent)
    }
    return "\(intent.label ?? rules.title(for: intent)). Option-Command-Return: \(other)."
  }
}
