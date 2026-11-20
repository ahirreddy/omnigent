import SwiftUI

/// The editor's Project choice (the web's project picker): No project, the caller's projects, a
/// project chosen by name that saving makes ("Omnigent Automation" for a new automation), and
/// New Project… to name one.
struct AutomationProjectMenu: View {
  @Binding var draft: AutomationDraftState
  let projects: [AutomationOption]
  @State private var naming = false
  @State private var newName = ""

  /// The project shown: the chosen one, one named that already exists, the name to make, or
  /// none; a saved project that is gone reads as unavailable.
  var title: String {
    if !draft.projectID.isEmpty {
      return projects.first { $0.id == draft.projectID }?.name ?? "Project unavailable"
    }
    return draft.projectName ?? "No project"
  }

  var body: some View {
    Menu(title) {
      choice("No project", selected: draft.projectID.isEmpty && draft.projectName == nil) {
        draft.projectID = ""
        draft.projectName = nil
      }
      if !projects.isEmpty { Divider() }
      ForEach(projects) { project in
        choice(project.name, selected: isSelected(project)) {
          draft.projectID = project.id
          draft.projectName = nil
        }
      }
      if let name = draft.projectName, !projects.contains(where: { $0.name == name }) {
        choice(name, selected: draft.projectID.isEmpty) {}
      }
      Divider()
      Button("New Project\u{2026}") {
        newName = ""
        naming = true
      }
    }
    .fixedSize()
    .accessibilityIdentifier("automation-project")
    .alert("New Project", isPresented: $naming) {
      TextField("Name", text: $newName)
      Button("Cancel", role: .cancel) {}
      Button("Create") {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        draft.projectID = ""
        draft.projectName = name
      }
    } message: {
      Text("The project is made when you save the automation.")
    }
  }

  private func isSelected(_ project: AutomationOption) -> Bool {
    draft.projectID.isEmpty ? project.name == draft.projectName : project.id == draft.projectID
  }

  private func choice(
    _ title: String, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
  }
}
