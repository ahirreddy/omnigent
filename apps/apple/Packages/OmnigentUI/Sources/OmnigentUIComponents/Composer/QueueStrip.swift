import SwiftUI

/// Messages waiting for the running turn to end, in send order, under "Queued · after this turn".
/// Each has labelled Edit, Send now (steers the running turn; Retry after a failure) and Remove
/// actions, always visible. Editing happens in place, so the draft below is never replaced; Esc
/// cancels the edit only. The handle drags a message to another place in the order; the context
/// menu moves it up or down.
struct QueueStrip: View {
  let queue: [QueuedMessage]
  let isRunning: Bool
  let canSteer: Bool
  let actions: ComposerExtraActions

  @State private var editingID: String?
  @State private var editText = ""
  @FocusState private var isEditorFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      HStack(spacing: Theme.Spacing.extraSmall) {
        Image(systemName: "clock").accessibilityHidden(true)
        Text(ComposerSendIntent.queue.label ?? "Queued")
        Spacer(minLength: 0)
        Text(queue.count == 1 ? "1 message" : "\(queue.count) messages")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, Theme.Spacing.medium)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("queue-header")
      ForEach(queue) { message in
        Group {
          if editingID == message.id {
            editor(message)
          } else {
            row(message)
          }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .cardSurface(cornerRadius: Theme.Radius.medium)
        .dropDestination(for: String.self) { ids, _ in
          guard let id = ids.first else { return false }
          return move(id, before: message.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queued-\(message.id)")
      }
    }
  }

  private func row(_ message: QueuedMessage) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
      if canReorder(message) {
        Image(systemName: "line.3.horizontal")
          .foregroundStyle(.tertiary)
          .help("Drag to reorder")
          .draggable(message.id) {
            Text(message.text).lineLimit(1).padding(Theme.Spacing.small)
          }
          .accessibilityLabel("Reorder")
          .accessibilityIdentifier("queued-handle-\(message.id)")
      }
      Text(message.text)
        .font(.callout)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
      stateLabel(message.state)
      ViewThatFits(in: .horizontal) {
        buttons(message).labelStyle(.titleAndIcon)
        buttons(message).labelStyle(.iconOnly)
      }
      .fixedSize()
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .tint(.secondary)
    .contextMenu {
      buttons(message)
      if canReorder(message), let index = queue.firstIndex(of: message) {
        Button("Move Up", systemImage: "arrow.up.to.line") {
          actions.moveQueued?(IndexSet([index]), index - 1)
        }
        .disabled(index == 0)
        Button("Move Down", systemImage: "arrow.down.to.line") {
          actions.moveQueued?(IndexSet([index]), index + 2)
        }
        .disabled(index == queue.count - 1)
      }
    }
  }

  private func canReorder(_ message: QueuedMessage) -> Bool {
    actions.moveQueued != nil && queue.count > 1 && message.state != .sending
  }

  /// Moves the dragged message `id` to just before `target` (after it when dragged downward).
  private func move(_ id: String, before target: String) -> Bool {
    guard let move = actions.moveQueued, id != target,
      let from = queue.firstIndex(where: { $0.id == id }),
      let to = queue.firstIndex(where: { $0.id == target }), queue[from].state != .sending
    else { return false }
    move(IndexSet([from]), from < to ? to + 1 : to)
    return true
  }

  @ViewBuilder
  private func buttons(_ message: QueuedMessage) -> some View {
    HStack(spacing: Theme.Spacing.small) {
      if actions.editQueued != nil, canEdit(message) {
        Button("Edit", systemImage: "pencil") { beginEditing(message) }
          .help("Edit this queued message")
          .accessibilityIdentifier("queued-edit-\(message.id)")
      }
      if let sendNow = actions.sendQueuedNow, let title = sendTitle(message) {
        Button(title, systemImage: "arrow.up") { sendNow(message) }
          .help(sendHelp(message))
          .accessibilityIdentifier("queued-send-now-\(message.id)")
      }
      if let remove = actions.removeQueued, message.state != .sending {
        Button("Remove", systemImage: "xmark") { remove(message) }
          .help("Remove from the queue")
          .accessibilityIdentifier("queued-remove-\(message.id)")
      }
    }
  }

  private func editor(_ message: QueuedMessage) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
      TextField("Queued message", text: $editText, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.callout)
        .lineLimit(1...6)
        .focused($isEditorFocused)
        .onSubmit { save(message) }
        .onKeyPress(.escape) {
          cancelEditing()
          return .handled
        }
        .accessibilityIdentifier("queued-editor-\(message.id)")
      Button("Cancel", action: cancelEditing)
        .accessibilityIdentifier("queued-edit-cancel-\(message.id)")
      Button("Save") { save(message) }
        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("queued-edit-save-\(message.id)")
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
  }

  @ViewBuilder
  private func stateLabel(_ state: QueuedMessage.State) -> some View {
    switch state {
    case .queued:
      EmptyView()
    case .sending:
      HStack(spacing: Theme.Spacing.extraSmall) {
        ProgressView().controlSize(.mini)
        Text("Sending")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    case .waitingForHost:
      Text("Waiting for host").font(.caption).foregroundStyle(.secondary)
    case .failed(let message):
      Label("Send failed", systemImage: "exclamationmark.circle")
        .font(.caption)
        .foregroundStyle(Theme.failure)
        .help(message)
        .accessibilityValue(message)
    }
  }

  private func canEdit(_ message: QueuedMessage) -> Bool {
    switch message.state {
    case .queued, .failed, .waitingForHost: true
    case .sending: false
    }
  }

  /// "Send now" steers the running turn; "Retry" resends a failure; nothing while sending, or
  /// while a turn runs on a harness that cannot take mid-turn input (it sends after the turn).
  private func sendTitle(_ message: QueuedMessage) -> String? {
    switch message.state {
    case .sending, .waitingForHost: nil
    case .failed: "Retry"
    case .queued: isRunning && !canSteer ? nil : "Send now"
    }
  }

  private func sendHelp(_ message: QueuedMessage) -> String {
    if case .failed = message.state { return "Send this message again" }
    return isRunning ? "Send now and steer the running turn" : "Send now"
  }

  private func beginEditing(_ message: QueuedMessage) {
    editText = message.text
    editingID = message.id
    isEditorFocused = true
  }

  private func cancelEditing() {
    editingID = nil
    editText = ""
  }

  private func save(_ message: QueuedMessage) {
    let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    actions.editQueued?(message, text)
    cancelEditing()
  }
}
