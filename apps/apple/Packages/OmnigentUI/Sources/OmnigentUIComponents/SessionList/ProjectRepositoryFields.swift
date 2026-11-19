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

  /// Creates an empty draft.
  public init() {}

  /// Whether the project starts from a repository: always on a sandbox, by choice on a host.
  public func startsFromRepository(_ choices: [ProjectRunChoice]) -> Bool {
    fromRepository || choices.first { $0.id == targetID }?.isSandbox == true
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

  /// Creates actions; every one is optional.
  public init() {}
}

/// New project's "Run on", Folder or Repository, and the repository, its branch and where a host
/// clones it (`project_repository_creation`).
struct ProjectRepositoryFields: View {
  let choices: [ProjectRunChoice]
  @Binding var draft: ProjectRepositoryDraft
  let actions: ProjectCreationActions

  private var choice: ProjectRunChoice? { choices.first { $0.id == draft.targetID } }
  private var isSandbox: Bool { choice?.isSandbox == true }

  var body: some View {
    Section {
      Picker("Run on", selection: $draft.targetID) {
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
    if draft.startsFromRepository(choices) { repository }
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
      draft.destination = actions.cloneDestination?(url) ?? ""
    }
  }
}
