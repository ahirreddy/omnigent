import SwiftUI

/// Where a new project's sessions can run: one of the caller's online hosts, or a new sandbox.
nonisolated public struct ProjectRunChoice: Hashable, Sendable, Identifiable {
  /// The host id, or the sandbox's own id from the adapter.
  public var id: String
  /// The name it shows: the host's, or "Modal Sandbox".
  public var title: String
  /// A new sandbox for each session, which always starts from a repository.
  public var isSandbox: Bool

  /// Creates a choice.
  public init(id: String, title: String, isSandbox: Bool = false) {
    self.id = id
    self.title = title
    self.isSandbox = isSandbox
  }
}

/// What New project's repository fields hold, as the web's dialog.
nonisolated public struct ProjectRepositoryDraft: Hashable, Sendable {
  /// The chosen ``ProjectRunChoice``.
  public var targetID: String?
  /// Repository, rather than Folder, for a host.
  public var fromRepository = false
  /// The repository's URL.
  public var url = ""
  /// Its branch; blank for the default.
  public var branch = ""
  /// Where a host clones it.
  public var destination = ""
  /// The user typed the destination, so the URL no longer names it.
  public var destinationEdited = false
  /// The folder a host clones into, from Browse; the repository's name follows it.
  public var cloneParent = "~"
  /// The user picked Run on, so the project keeps that host even without a folder.
  public var targetChosen = false
  /// A folder project's working directory on its host, from Browse.
  public var workspace = ""
  /// Create `~/<project name>` on the host as the working directory.
  public var createsFolder = false
  /// The folder an earlier attempt created, so a retry doesn't create it again.
  public var createdFolder: CreatedFolder?

  /// A folder made on a host for a project.
  public struct CreatedFolder: Hashable, Sendable {
    /// The host.
    public var hostID: String
    /// The project name it was made for.
    public var name: String
    /// Its absolute path.
    public var path: String

    /// Creates a record of a made folder.
    public init(hostID: String, name: String, path: String) {
      self.hostID = hostID
      self.name = name
      self.path = path
    }
  }

  /// Creates an empty draft.
  public init() {}

  /// Whether the project starts from a repository: always on a sandbox, by choice on a host.
  public func startsFromRepository(_ choices: [ProjectRunChoice]) -> Bool {
    fromRepository || choices.first { $0.id == targetID }?.isSandbox == true
  }

  /// Whether a Folder project names its host (the web saves the host only when the user picked
  /// it or a working directory).
  public var namesHost: Bool { targetChosen || createsFolder || !workspace.isEmpty }

  /// `parent` joined with a repository name, as the web's `joinPath`.
  public static func join(_ parent: String, _ name: String) -> String {
    let base = parent.hasSuffix("/") ? String(parent.dropLast()) : parent
    return base.isEmpty ? name : "\(base)/\(name)"
  }
}

/// What New project from a repository reads and does.
public struct ProjectCreationActions {
  /// Makes the project (name, icon, the draft); returns the words to show when it fails.
  public var create: (@MainActor (String, String?, ProjectRepositoryDraft) async -> String?)?
  /// Why a repository and branch can't be used, or `nil`.
  public var problem: (@MainActor (String, String) -> String?)?
  /// Where a host clones a repository unless the user says otherwise.
  public var cloneDestination: (@MainActor (String) -> String?)?
  /// Reads the hosts and sandboxes a project can run on.
  public var loadChoices: (@MainActor () -> Void)?
  /// Makes a Folder project (name, icon, the draft); returns the words to show when it fails.
  public var createFolderProject:
    (@MainActor (String, String?, ProjectRepositoryDraft) async -> String?)?
  /// Creates `~/<name>` on a host: its path, or the words to show.
  public var createFolder: (@MainActor (String, String) async -> Result<String, FolderBrowseError>)?
  /// Lists a host's folders, for Browse.
  public var browse:
    (@MainActor (String, String?) async -> Result<FolderListing, FolderBrowseError>)?

  /// Creates actions; every one is optional.
  public init() {}
}

/// New project's "Run on", Folder or Repository: a Folder project's optional working directory,
/// or the repository, its branch and where a host clones it (`project_repository_creation`).
struct ProjectRepositoryFields: View {
  let choices: [ProjectRunChoice]
  @Binding var draft: ProjectRepositoryDraft
  let actions: ProjectCreationActions
  /// The project's name, which a created folder takes.
  let projectName: String

  @State private var browsing: Browse?

  /// What Browse picks: the working directory, or the folder a repository is cloned into.
  private enum Browse: Identifiable {
    case workspace, cloneParent
    var id: Self { self }
  }

  private var choice: ProjectRunChoice? { choices.first { $0.id == draft.targetID } }
  private var isSandbox: Bool { choice?.isSandbox == true }

  var body: some View {
    Section {
      Picker("Run on", selection: runOn) {
        if choices.isEmpty { Text("No host available").tag(String?.none) }
        ForEach(choices) { Text($0.title).tag(Optional($0.id)) }
      }
      .accessibilityIdentifier("project-run-on")
      if !isSandbox {
        Picker("Source", selection: $draft.fromRepository) {
          Text("Folder").tag(false)
          Text("Repository").tag(true)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("project-source")
      }
    }
    .onAppear {
      actions.loadChoices?()
      if draft.targetID == nil { draft.targetID = choices.first?.id }
    }
    .onChange(of: choices) { _, choices in
      if draft.targetID == nil { draft.targetID = choices.first?.id }
    }
    if draft.startsFromRepository(choices) {
      repository
    } else if choice != nil {
      workingDirectory
    }
  }

  /// The picker's binding: a choice the user makes is kept as the project's host.
  private var runOn: Binding<String?> {
    Binding(
      get: { draft.targetID },
      set: {
        draft.targetID = $0
        draft.targetChosen = true
      })
  }

  /// Folder: where the project's sessions start, picked on the host or made from its name.
  private var workingDirectory: some View {
    Section {
      Toggle("Create a folder using the project name", isOn: $draft.createsFolder)
        .accessibilityIdentifier("project-create-folder")
      LabeledContent("Folder") {
        HStack(spacing: Theme.Spacing.small) {
          Text(folderShown)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(folderShown)
          Button("Browse\u{2026}") { browsing = .workspace }
            .disabled(draft.createsFolder || actions.browse == nil)
            .accessibilityIdentifier("project-workspace-browse")
        }
      }
    } header: {
      Text("Working Directory")
    } footer: {
      Text("Optional. Sessions in this project start here.")
    }
    .sheet(item: $browsing) { browse in folderBrowser(browse) }
  }

  private var folderShown: String {
    if draft.createsFolder {
      let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
      return ProjectRepositoryDraft.join("~", name.isEmpty ? "Project name" : name)
    }
    return draft.workspace.isEmpty ? "Not selected" : draft.workspace
  }

  @ViewBuilder private func folderBrowser(_ browse: Browse) -> some View {
    if let hostID = draft.targetID, let load = actions.browse {
      FolderBrowserView(
        initialPath: browse == .workspace
          ? (draft.workspace.isEmpty ? nil : draft.workspace) : draft.cloneParent,
        load: { await load(hostID, $0) },
        choose: { path in
          switch browse {
          case .workspace: draft.workspace = path
          case .cloneParent:
            draft.cloneParent = path
            draft.destinationEdited = false
            draft.destination = cloneDestination(draft.url)
          }
          browsing = nil
        },
        cancel: { browsing = nil })
    }
  }

  /// The repository's folder inside the chosen parent.
  private func cloneDestination(_ url: String) -> String {
    guard let suggested = actions.cloneDestination?(url),
      let name = suggested.split(separator: "/").last
    else { return "" }
    return ProjectRepositoryDraft.join(draft.cloneParent, String(name))
  }

  private var repository: some View {
    Section {
      TextField("Repository URL", text: $draft.url, prompt: Text("https://github.com/org/repo"))
        .autocorrectionDisabled()
        .accessibilityIdentifier("project-repository-url")
      TextField("Branch", text: $draft.branch, prompt: Text("Default branch"))
        .autocorrectionDisabled()
        .accessibilityIdentifier("project-repository-branch")
      if !isSandbox {
        HStack(spacing: Theme.Spacing.small) {
          TextField(
            "Clone into",
            text: Binding(
              get: { draft.destination },
              set: {
                draft.destination = $0
                draft.destinationEdited = true
              }),
            prompt: Text("~/repository")
          )
          .autocorrectionDisabled()
          .accessibilityIdentifier("project-clone-into")
          Button("Browse\u{2026}") { browsing = .cloneParent }
            .disabled(actions.browse == nil)
            .accessibilityIdentifier("project-clone-browse")
        }
      }
      if let problem = actions.problem?(draft.url, draft.branch) {
        Text(problem).font(.callout).foregroundStyle(Theme.failure)
          .accessibilityIdentifier("project-repository-problem")
      }
    } header: {
      Text("Repository")
    } footer: {
      Text(
        isSandbox
          ? "Saved with this project. The repository will be prepared when you start a session."
          : "Cloned onto \(choice?.title ?? "the host") before the project is saved.")
    }
    .onChange(of: draft.url) { _, url in
      guard !draft.destinationEdited else { return }
      draft.destination = cloneDestination(url)
    }
    .sheet(item: $browsing) { browse in folderBrowser(browse) }
  }
}
