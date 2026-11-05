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

/// The header's project tag, as the web's breadcrumb folder: the project's icon (its name in the
/// tooltip), or "Add to project" when unfiled. Choosing a project moves the session there.
struct HeaderProjectTag: View {
  let session: SessionSummary
  let context: SessionMenuContext
  let move: @MainActor (SessionSummary, SessionProject?) -> Void

  var body: some View {
    let current = context.project
    Menu {
      ForEach(context.projects) { project in
        Button(project.name) { move(session, project) }
          .disabled(project.id == current?.id)
      }
      if current != nil {
        Divider()
        Button("Remove from Project", systemImage: "folder.badge.minus") { move(session, nil) }
      }
    } label: {
      if let icon = current?.icon, !icon.isEmpty {
        Label {
          Text(current?.name ?? "")
        } icon: {
          Text(icon)
        }
      } else {
        Label(
          current?.name ?? "Add to project",
          systemImage: current == nil ? "folder.badge.plus" : "folder")
      }
    }
    .menuIndicator(.hidden)
    .help(current.map { "Project: \($0.name). Move to another project" } ?? "Add to project")
    .accessibilityIdentifier("header-project-tag")
  }

  /// Whether the tag applies: the viewer's own top-level session, with projects to file into.
  static func applies(
    _ context: SessionMenuContext, isSubagent: Bool, canMove: Bool
  ) -> Bool {
    canMove && !context.isShared && !isSubagent && !context.projects.isEmpty
  }
}

/// "Created by <session>" under the header for an independent worker, linking back to the
/// session that started it (the web's `CreatedBySession`).
struct CreatedByBar: View {
  let creator: CreatingSession
  let open: @MainActor (String) -> Void

  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      Text("Created by")
        .foregroundStyle(.secondary)
      Button(creator.title ?? "another session") { open(creator.id) }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .lineLimit(1)
        .help("Open the session that created this worker")
        .accessibilityIdentifier("session-created-by")
      Spacer(minLength: 0)
    }
    .font(.caption)
    .padding(.horizontal, Theme.Spacing.large)
    .padding(.vertical, Theme.Spacing.extraSmall)
    .accessibilityElement(children: .contain)
  }
}
