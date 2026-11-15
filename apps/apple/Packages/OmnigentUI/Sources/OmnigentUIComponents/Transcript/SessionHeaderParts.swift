public import SwiftUI

extension View {
  /// The Rename Session prompt: the title, Rename and Cancel. The title is trimmed and must be
  /// 1 to 120 characters, as the server requires.
  /// - Parameters:
  ///   - renaming: The session being renamed; `nil` hides the prompt.
  ///   - text: The edited title.
  ///   - rename: Saves the new title.
  /// - Returns: The view with the prompt.
  public func sessionRenamePrompt(
    _ renaming: Binding<SessionSummary?>, text: Binding<String>,
    rename: (@MainActor (SessionSummary, String) -> Void)?
  ) -> some View {
    let trimmed = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return alert(
      "Rename Session",
      isPresented: Binding(
        get: { renaming.wrappedValue != nil }, set: { if !$0 { renaming.wrappedValue = nil } })
    ) {
      TextField("Title", text: text)
      Button("Rename") {
        if let session = renaming.wrappedValue { rename?(session, trimmed) }
        renaming.wrappedValue = nil
      }
      .disabled(trimmed.isEmpty || trimmed.count > 120)
      Button("Cancel", role: .cancel) { renaming.wrappedValue = nil }
    }
  }
}

/// "Created by <session>" under the header for an independent worker, "Sub-agent of <session>"
/// for a sub-agent, or "Side chat of <session>" for a side chat, linking to that session (the
/// web's `CreatedBySession` and breadcrumb).
struct SessionOriginBar: View {
  enum Relation {
    case createdBy
    case subagentOf
    case sideChatOf

    var label: String {
      switch self {
      case .createdBy: "Created by"
      case .subagentOf: "Sub-agent of"
      case .sideChatOf: "Side chat of"
      }
    }

    var help: String {
      switch self {
      case .createdBy: "Open the session that created this worker"
      case .subagentOf: "Go back to the session that started this sub-agent"
      case .sideChatOf: "Go back to the conversation this side chat is about"
      }
    }

    var identifier: String {
      switch self {
      case .createdBy: "session-created-by"
      case .subagentOf: "session-open-parent"
      case .sideChatOf: "sidechat-open-parent"
      }
    }
  }

  let relation: Relation
  let origin: CreatingSession
  let open: @MainActor (String) -> Void

  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      Text(relation.label)
        .foregroundStyle(.secondary)
      Button(origin.title ?? "another session") { open(origin.id) }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .lineLimit(1)
        .help(relation.help)
        .accessibilityIdentifier(relation.identifier)
      Spacer(minLength: 0)
    }
    .font(.caption)
    .padding(.horizontal, Theme.Spacing.large)
    .padding(.vertical, Theme.Spacing.small)
    // A bar of its own: the transcript scrolls under it, not through it.
    .background { ThemeCanvas(isBar: true) }
    .overlay(alignment: .bottom) { Divider() }
    .accessibilityElement(children: .contain)
  }
}
