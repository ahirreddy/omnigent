import SwiftUI

/// What the project name prompt is for.
enum ProjectPrompt: Identifiable {
  /// A new project, moving the session into it when one is given.
  case create(moving: SessionSummary?)
  /// Renaming a project.
  case rename(SessionProject)

  var id: String {
    switch self {
    case .create(let session): "create-\(session?.id ?? "")"
    case .rename(let project): "rename-\(project.id)"
    }
  }
}

/// The project name prompt (New project, Rename) and the Delete project confirmation.
struct ProjectDialogs: ViewModifier {
  @Binding var prompt: ProjectPrompt?
  @Binding var name: String
  @Binding var confirmingDelete: SessionProject?
  let actions: SidebarActions

  /// The server's limit.
  private static let maxNameLength = 120

  func body(content: Content) -> some View {
    content
      .alert(
        title,
        isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
      ) {
        TextField("Name", text: $name)
        Button(confirmTitle, action: submit)
          .disabled(trimmed.isEmpty || trimmed.count > Self.maxNameLength)
        Button("Cancel", role: .cancel) { prompt = nil }
      }
      .confirmationDialog(
        "Delete this project?",
        isPresented: Binding(
          get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
        presenting: confirmingDelete
      ) { project in
        Button("Delete Project", role: .destructive) { actions.deleteProject?(project) }
      } message: { _ in
        Text("Its sessions are archived and removed from the project; none are deleted.")
      }
  }

  private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var title: String {
    if case .rename = prompt { return "Rename Project" }
    return "New Project"
  }

  private var confirmTitle: String {
    if case .rename = prompt { return "Rename" }
    return "Create"
  }

  private func submit() {
    switch prompt {
    case .create(let session): actions.createProject?(trimmed, session)
    case .rename(let project): actions.renameProject?(project, trimmed)
    case nil: break
    }
    prompt = nil
  }
}
