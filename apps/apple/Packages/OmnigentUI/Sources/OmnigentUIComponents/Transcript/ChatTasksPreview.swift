public import SwiftUI

/// The chat's one-line task preview (the web's `ChatTasksPreview`): "Tasks 3/7 · Profiling the
/// request".
nonisolated public struct ChatTasksPreviewState: Hashable, Sendable {
  /// The words that lead a task waiting for the user.
  public static let waitingForYou = "Waiting for you"

  /// Tasks finished, failed ones included.
  public var finished: Int
  /// All the tasks.
  public var total: Int
  /// The task waiting, running or next, or how they finished; `nil` says nothing more.
  public var text: String?
  /// The plan's name, which the preview's tooltip shows.
  public var planName: String?

  /// Creates a preview.
  /// - Parameters:
  ///   - finished: Finished tasks.
  ///   - total: All tasks.
  ///   - text: The line after the count.
  ///   - planName: The plan's name.
  public init(finished: Int, total: Int, text: String?, planName: String?) {
    self.finished = finished
    self.total = total
    self.text = text
    self.planName = planName
  }

  /// A task waits for the user, which the line names first.
  var isWaiting: Bool { text?.hasPrefix("\(Self.waitingForYou):") == true }

  /// What VoiceOver reads.
  var accessibilityLabel: String {
    let plan = planName.map { " for \($0)" } ?? ""
    let rest = text.map { ": \($0)" } ?? ""
    return "Tasks\(plan), \(finished) of \(total) finished\(rest)"
  }
}

/// The preview pinned above the chat while the session has tasks; a click opens the Tasks tab.
/// It reads the tasks itself, so their changes draw it and not the conversation.
struct ChatTasksPreviewBar: View {
  let read: @MainActor () -> ChatTasksPreviewState?
  let open: @MainActor () -> Void

  var body: some View {
    if let state = read() {
      Button(action: open) { label(state) }
        .buttonStyle(.plain)
        .help(state.planName ?? "Show the Tasks tab")
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityHint("Shows the Tasks tab")
        .accessibilityIdentifier("tasks-preview")
        .frame(maxWidth: Theme.transcriptWidth)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.extraSmall)
    }
  }

  private func label(_ state: ChatTasksPreviewState) -> some View {
    HStack(spacing: Theme.Spacing.small) {
      Image(systemName: "checklist").accessibilityHidden(true)
      Text("Tasks").fontWeight(.medium)
      Text("\(state.finished)/\(state.total)").monospacedDigit().foregroundStyle(.secondary)
      if let text = state.text {
        Text("\u{b7}").foregroundStyle(.tertiary)
        line(text, waiting: state.isWaiting)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Spacer(minLength: 0)
      }
      Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .font(.callout)
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.small)
    .background(.tint.opacity(0.1), in: shape)
    .overlay { shape.strokeBorder(.tint.opacity(0.25)) }
    .contentShape(shape)
  }

  /// "Waiting for you" stands out in the attention color, as a session that needs the user.
  private func line(_ text: String, waiting: Bool) -> Text {
    guard waiting else { return Text(text) }
    let lead = ChatTasksPreviewState.waitingForYou
    let marked = Text(lead).fontWeight(.medium).foregroundStyle(Theme.attention)
    return Text("\(marked)\(String(text.dropFirst(lead.count)))")
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
  }
}
