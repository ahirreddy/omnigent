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
  /// Where a new project from a repository can run; empty offers none.
  var runChoices: [ProjectRunChoice] = []
  @State private var icon = ""
  @State private var repository = ProjectRepositoryDraft()

  func body(content: Content) -> some View {
    content
      .sheet(item: $prompt) { prompt in
        ProjectNameSheet(
          prompt: prompt, name: $name, icon: $icon, repository: $repository,
          runChoices: offersRepository(prompt) ? runChoices : [],
          creation: actions.repositoryProjects,
          submit: { submit(prompt) }, createFromRepository: createFromRepository,
          cancel: { self.prompt = nil }
        )
        .onAppear {
          if case .rename(let project) = prompt { icon = project.icon ?? "" } else { icon = "" }
          repository = ProjectRepositoryDraft()
        }
      }
      .confirmationDialog(
        "Delete project?",
        isPresented: Binding(
          get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
        presenting: confirmingDelete
      ) { project in
        Button("Delete Project", role: .destructive) { actions.deleteProject?(project) }
      } message: { project in
        Text(
          "This deletes the project \(project.name) and archives all of its sessions. Their "
            + "history is kept. You can find and restore them anytime from Settings.")
      }
  }

  /// A new project not moving a session in, on a server that clones repositories.
  private func offersRepository(_ prompt: ProjectPrompt) -> Bool {
    guard case .create(nil) = prompt else { return false }
    return actions.repositoryProjects.create != nil
  }

  /// Creates the project from the repository; the sheet stays open with the reason on failure.
  private func createFromRepository() async -> String? {
    guard let create = actions.repositoryProjects.create else { return nil }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let failure = await create(name, ProjectNameSheet.icon(icon), repository)
    if failure == nil { prompt = nil }
    return failure
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
  @Binding var repository: ProjectRepositoryDraft
  /// Where it can run from a repository; empty shows name and icon only.
  let runChoices: [ProjectRunChoice]
  let creation: ProjectCreationActions
  let submit: () -> Void
  let createFromRepository: () async -> String?
  let cancel: () -> Void
  @FocusState private var iconFocused: Bool
  @State private var isCreating = false
  @State private var failure: String?

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
        if !runChoices.isEmpty {
          ProjectRepositoryFields(
            choices: runChoices, draft: $repository, actions: creation, projectName: name)
        }
        if let failure {
          Text(failure).foregroundStyle(Theme.failure)
            .accessibilityIdentifier("project-create-failure")
        }
      }
      .formStyle(.grouped)
      .disabled(isCreating)
      .navigationTitle(isRename ? "Rename Project" : "New Project")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
        ToolbarItem(placement: .confirmationAction) {
          Button(isRename ? "Rename" : "Create", action: create)
            .disabled(trimmed.isEmpty || trimmed.count > Self.maxNameLength || isCreating)
        }
      }
    }
    #if os(macOS)
      .frame(width: 380)
    #endif
    .accessibilityIdentifier("project-name-sheet")
  }

  /// Creates as the sheet says: from the repository, which can take minutes to clone, in a
  /// folder on the chosen host, else by name and icon.
  private func create() {
    guard !runChoices.isEmpty else {
      submit()
      return
    }
    guard repository.startsFromRepository(runChoices) else {
      createInFolder()
      return
    }
    if repository.url.trimmingCharacters(in: .whitespaces).isEmpty {
      failure = "Add the repository this project starts from."
      return
    }
    if let problem = creation.problem?(repository.url, repository.branch) {
      failure = problem
      return
    }
    failure = nil
    isCreating = true
    Task {
      failure = await createFromRepository()
      isCreating = false
    }
  }

  /// A Folder project: the host the user picked, and the folder it chose or creates.
  private func createInFolder() {
    guard repository.namesHost, let createFolderProject = creation.createFolderProject else {
      submit()
      return
    }
    failure = nil
    isCreating = true
    Task {
      failure = await folderProject(createFolderProject)
      isCreating = false
    }
  }

  private func folderProject(
    _ create: @MainActor (String, String?, ProjectRepositoryDraft) async -> String?
  ) async -> String? {
    var draft = repository
    if draft.createsFolder {
      guard let hostID = draft.targetID, let createFolder = creation.createFolder else {
        return "Connect a host before creating a working directory."
      }
      if let made = draft.createdFolder, made.hostID == hostID, made.name == trimmed {
        draft.workspace = made.path
      } else {
        switch await createFolder(hostID, trimmed) {
        case .success(let path):
          draft.workspace = path
          repository.createdFolder = .init(hostID: hostID, name: trimmed, path: path)
        case .failure(let error):
          return error.message
        }
      }
    }
    let failure = await create(trimmed, Self.icon(icon), draft)
    // Made: the sheet closes as Cancel closes it.
    if failure == nil { cancel() }
    return failure
  }

  private var isRename: Bool {
    if case .rename = prompt { return true }
    return false
  }

  private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}
