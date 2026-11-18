public import SwiftUI

/// A project delete waiting on a confirmation: some of its sessions' agents are working, and
/// archiving them stops them.
nonisolated public struct ProjectDeleteRunningRequest: Hashable, Sendable, Identifiable {
  /// The project.
  public var project: SessionProject
  /// Its sessions whose agents are working.
  public var runningCount: Int

  /// The project, as the dialog's identity.
  public var id: String { project.id }

  /// Creates a request.
  public init(project: SessionProject, runningCount: Int) {
    self.project = project
    self.runningCount = runningCount
  }

  /// The dialog's message, as the web words it.
  public var message: String {
    runningCount == 1
      ? "1 session in \(project.name) has an agent still working. Deleting the project archives "
        + "it, which stops its agent."
      : "\(runningCount) sessions in \(project.name) have agents still working. Deleting the "
        + "project archives them, which stops their agents."
  }
}

extension View {
  /// Asks again before deleting a project whose agents are working; dismissing cancels.
  /// - Parameters:
  ///   - request: The pending delete; `nil` hides the dialog.
  ///   - delete: Called when the user deletes anyway.
  /// - Returns: The view with the dialog.
  public func projectDeleteRunningPrompt(
    _ request: Binding<ProjectDeleteRunningRequest?>,
    delete: @escaping @MainActor (SessionProject) -> Void
  ) -> some View {
    background {
      Color.clear.confirmationDialog(
        "Delete project?",
        isPresented: Binding(
          get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }),
        titleVisibility: .visible, presenting: request.wrappedValue
      ) { pending in
        Button("Delete Anyway", role: .destructive) {
          request.wrappedValue = nil
          delete(pending.project)
        }
        .accessibilityIdentifier("project-delete-anyway")
        Button("Cancel", role: .cancel) {}
      } message: { pending in
        Text(pending.message)
      }
    }
  }
}
