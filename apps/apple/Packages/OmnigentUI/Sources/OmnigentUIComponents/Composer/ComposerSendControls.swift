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
      canQueue: canQueue, prefersSteer: state.prefersSteer)
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
    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, state.attachments.isEmpty,
      state.mentions.isEmpty, state.quotes.isEmpty
    {
      return state.purpose == .start ? "Enter a message to get started" : "Type a message."
    }
    return nil
  }

  /// Why `intent` cannot run now, or `nil`. A queued message takes the draft's files with it.
  /// - Parameter intent: The intent.
  /// - Returns: The reason.
  func blockedReason(for intent: ComposerSendIntent) -> String? {
    sendBlockedReason
  }

  /// The draft has text, files, `@` paths or quotes.
  var hasContent: Bool {
    !draft.isEmpty || !state.attachments.isEmpty || !state.mentions.isEmpty
      || !state.quotes.isEmpty
  }

  /// The placeholder, in the web's words: what needs the user first, why sending waits, or what
  /// a send does while a turn runs. The Mac's default one also names the keys ("↵ to send now,
  /// ⌥⌘↵ to queue for later", ⌘↵ with the Command-Return setting) and Esc while running.
  var placeholder: String {
    if let status = state.statusPlaceholder { return status }
    if state.purpose == .session, let reason = state.availability.reason { return reason }
    guard state.placeholder == ComposerViewState().placeholder else { return state.placeholder }
    let lead =
      switch state.isRunning ? intent : .send {
      case .steer: "Steer the agent"
      case .queue: "Send a follow-up (queued)"
      case .send: "Send a message"
      }
    guard layout != .touch else { return lead + "\u{2026}" }
    return "\(lead) \u{2014} \(keyHints)" + (state.isRunning ? ", Esc to stop" : "")
  }

  /// What Return does, then Option-Command-Return's alternative (or the newline key while idle).
  private var keyHints: String {
    let send = state.submitWithCommandReturn ? "\u{2318}\u{21B5}" : "\u{21B5}"
    let primary = "\(send) to \(Self.verb(intent))"
    if let alternative {
      return "\(primary), \u{2325}\u{2318}\u{21B5} to \(Self.verb(alternative))"
    }
    guard intent == .send else { return primary }
    let newline = state.submitWithCommandReturn ? "\u{21B5}" : "\u{21E7}\u{21B5}"
    return "\(primary), \(newline) for a new line"
  }

  private static func verb(_ intent: ComposerSendIntent) -> String {
    switch intent {
    case .send: "send"
    case .steer: "send now"
    case .queue: "queue for later"
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
/// ("Send now · steer" or "Queued · after this turn"); its menu offers the other choice. The
/// Mac's pill draws them as rounded squares and shows Send only when there is something to send.
struct ComposerSendControls: View {
  let state: ComposerViewState
  let rules: ComposerSendRules
  let hasDraft: Bool
  let perform: (ComposerSendIntent) -> Void
  let interrupt: (@MainActor () -> Void)?
  @Environment(\.commandReturnOwner) private var commandReturnOwner
  @Environment(\.composerLayoutStyle) private var layout
  @Environment(\.colorScheme) private var colorScheme

  /// A pending request's Approve has Command-Return; Send gives it up and says so.
  private var approveOwnsCommandReturn: Bool { commandReturnOwner == .approve }

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      if state.isRunning {
        stop
      }
      if layout == .card ? hasDraft || state.delivery == .sending : !state.isRunning || hasDraft {
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

  private var stopColors: (fill: Color, glyph: Color) {
    colorScheme == .dark ? (Color(white: 0.92), .black) : (Color(white: 0.1), .white)
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
      // A filled shape with a square, always in reach while the agent works. Fixed colors, as
      // glass would draw hierarchical styles vibrant (a washed-out gray).
      .foregroundStyle(stopColors.glyph)
      .frame(width: layout.sendCircle, height: layout.sendCircle)
      .background(stopColors.fill, in: layout.sendShape)
      .frame(width: layout.sendTarget, height: layout.sendTarget)
      .contentShape(layout.sendShape)
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
      .background(blocked == nil ? Theme.accent : ThemeColor.hover, in: layout.sendShape)
      .frame(width: layout.sendTarget, height: layout.sendTarget)
      .contentShape(layout.sendShape)
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
