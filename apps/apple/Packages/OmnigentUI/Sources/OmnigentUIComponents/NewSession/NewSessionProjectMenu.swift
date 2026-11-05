import SwiftUI

/// The new-session page's project chip (the web's "Work in a project"): the session is filed in
/// the chosen project from its creation.
struct NewSessionProjectMenu: View {
  /// The chosen project's name; `nil` for none.
  let project: String?
  /// The caller's projects, by name.
  let projects: [String]
  let select: @MainActor (String?) -> Void

  var body: some View {
    Menu {
      Button("No Project") { select(nil) }
      if !projects.isEmpty {
        Section("Projects") {
          ForEach(projects, id: \.self) { name in
            Button(name) { select(name) }
          }
        }
      }
    } label: {
      Label(project ?? "No project", systemImage: "rectangle.stack")
    }
    .fixedSize()
    .help("Work in a project: the session is filed there from the start")
    .accessibilityLabel("Project, \(project ?? "none")")
    .accessibilityIdentifier("new-session-project")
  }
}
