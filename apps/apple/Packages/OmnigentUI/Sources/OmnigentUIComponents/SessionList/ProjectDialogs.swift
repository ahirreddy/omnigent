import SwiftUI

#if os(macOS)
  import AppKit
#endif

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

/// The project name and icon sheet (New project, Rename project) and the Delete project
/// confirmation.
struct ProjectDialogs: ViewModifier {
  @Binding var prompt: ProjectPrompt?
  @Binding var name: String
  @Binding var confirmingDelete: SessionProject?
  let actions: SidebarActions
  @State private var icon = ""

  func body(content: Content) -> some View {
    content
      .sheet(item: $prompt) { prompt in
        ProjectNameSheet(
          prompt: prompt, name: $name, icon: $icon,
          submit: { submit(prompt) }, cancel: { self.prompt = nil }
        )
        .onAppear {
          if case .rename(let project) = prompt { icon = project.icon ?? "" } else { icon = "" }
        }
      }
      .confirmationDialog(
        "Delete this project?",
        isPresented: Binding(
          get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
        presenting: confirmingDelete
      ) { project in
        Button("Delete Project", role: .destructive) { actions.deleteProject?(project) }
      } message: { _ in
        Text(
          "Its sessions are archived and removed from the project; their history is kept. You "
            + "can find and restore them anytime from Settings.")
      }
  }

  private func submit(_ prompt: ProjectPrompt) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let icon = ProjectNameSheet.icon(icon)
    switch prompt {
    case .create(let session): actions.createProject?(name, icon, session)
    case .rename(let project): actions.renameProject?(project, name, icon)
    }
    self.prompt = nil
  }
}

/// The name field and emoji icon of a new or renamed project.
private struct ProjectNameSheet: View {
  let prompt: ProjectPrompt
  @Binding var name: String
  @Binding var icon: String
  let submit: () -> Void
  let cancel: () -> Void
  @FocusState private var iconFocused: Bool

  /// The server's limit.
  private static let maxNameLength = 120

  /// The first character of `text`, or `nil` for none (no icon).
  static func icon(_ text: String) -> String? {
    text.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init)
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $name)
          .accessibilityIdentifier("project-name-field")
        LabeledContent("Icon") {
          HStack(spacing: Theme.Spacing.small) {
            TextField("Icon", text: $icon, prompt: Text("None"))
              .labelsHidden()
              .focused($iconFocused)
              .frame(width: 48)
              .onChange(of: icon) { _, text in
                // Keep one emoji: the latest pick replaces the last one.
                let latest = text.last.map(String.init) ?? ""
                if latest != text { icon = latest }
              }
              .accessibilityIdentifier("project-icon-field")
            #if os(macOS)
              Button("Choose\u{2026}") {
                iconFocused = true
                NSApp.orderFrontCharacterPalette(nil)
              }
            #endif
            if !icon.isEmpty {
              Button("Remove icon", systemImage: "xmark.circle.fill") { icon = "" }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove icon")
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(isRename ? "Rename Project" : "New Project")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
        ToolbarItem(placement: .confirmationAction) {
          Button(isRename ? "Rename" : "Create", action: submit)
            .disabled(trimmed.isEmpty || trimmed.count > Self.maxNameLength)
        }
      }
    }
    #if os(macOS)
      .frame(width: 380)
    #endif
    .accessibilityIdentifier("project-name-sheet")
  }

  private var isRename: Bool {
    if case .rename = prompt { return true }
    return false
  }

  private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}
