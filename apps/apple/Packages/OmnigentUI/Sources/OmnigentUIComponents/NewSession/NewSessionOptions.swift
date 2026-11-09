import Foundation
public import SwiftUI

/// One existing git worktree offered on a new session.
nonisolated public struct NewSessionWorktreeOption: Hashable, Sendable, Identifiable {
  /// Absolute path.
  public var path: String
  /// Checked-out branch; `nil` when detached.
  public var branch: String?

  /// The path.
  public var id: String { path }

  /// Creates an option.
  /// - Parameters:
  ///   - path: Path.
  ///   - branch: Branch.
  public init(path: String, branch: String?) {
    self.path = path
    self.branch = branch
  }
}

/// Where a new session works in its folder's repository.
nonisolated public enum NewSessionWorktreeChoice: Hashable, Sendable {
  /// In the folder itself.
  case none
  /// A new worktree on a new branch, from `base` (empty for the repository default).
  case new(branch: String, base: String)
  /// An existing worktree.
  case existing(NewSessionWorktreeOption)
}

/// The new-session page's start options under the composer, as on the web: the folder (with
/// recents, a host folder browser and a typed path), the worktree, and a sandbox's repositories.
nonisolated public struct NewSessionOptions: Hashable, Sendable {
  /// The chosen folder; `nil` shows "Choose folder".
  public var folder: String?
  /// Folders offered as recents.
  public var recentFolders: [String]
  /// The session starts on a new sandbox: repositories replace the folder.
  public var isSandbox: Bool
  /// Repositories to clone into the sandbox.
  public var repositories: SandboxRepositoriesState
  /// The sandbox's profile, when its provider launches with one.
  public var profiles: SandboxProfilesState?
  /// The folder is a git repository, so worktrees are offered.
  public var offersWorktrees: Bool
  /// Existing worktrees, main excluded.
  public var worktrees: [NewSessionWorktreeOption]
  /// The worktree choice.
  public var worktree: NewSessionWorktreeChoice
  /// The selected agent is not ready on the host: `"<agent> isn't ready on <host>."`.
  public var harnessNotice: String?
  /// The Set Up button's agent name.
  public var setUpName: String?
  /// No host is online, so offer to connect one.
  public var needsHost = false
  /// Plan mode is armed for the launch.
  public var isPlanMode: Bool
  /// Settings › Git's default base branch, pre-filled when naming a new worktree branch.
  public var defaultBaseBranch: String
  /// The project the session is filed in; `nil` for none.
  public var project: String?
  /// The caller's projects, by name.
  public var projects: [String] = []

  /// Creates options.
  /// - Parameters:
  ///   - folder: Folder.
  ///   - recentFolders: Recents.
  ///   - isSandbox: New sandbox.
  ///   - repositories: Sandbox repositories.
  ///   - profiles: The sandbox profile picker.
  ///   - offersWorktrees: Git repository.
  ///   - worktrees: Existing worktrees.
  ///   - worktree: Worktree choice.
  ///   - harnessNotice: The not-ready notice.
  ///   - setUpName: The Set Up button's agent name.
  ///   - isPlanMode: Plan mode is armed.
  ///   - defaultBaseBranch: The base pre-filled for a new branch.
  public init(
    folder: String? = nil, recentFolders: [String] = [], isSandbox: Bool = false,
    repositories: SandboxRepositoriesState = SandboxRepositoriesState(),
    profiles: SandboxProfilesState? = nil, offersWorktrees: Bool = false,
    worktrees: [NewSessionWorktreeOption] = [], worktree: NewSessionWorktreeChoice = .none,
    harnessNotice: String? = nil, setUpName: String? = nil, isPlanMode: Bool = false,
    defaultBaseBranch: String = ""
  ) {
    self.folder = folder
    self.recentFolders = recentFolders
    self.isSandbox = isSandbox
    self.repositories = repositories
    self.profiles = profiles
    self.offersWorktrees = offersWorktrees
    self.worktrees = worktrees
    self.worktree = worktree
    self.harnessNotice = harnessNotice
    self.setUpName = setUpName
    self.isPlanMode = isPlanMode
    self.defaultBaseBranch = defaultBaseBranch
  }

  /// The worktree chip's title.
  public var worktreeTitle: String {
    switch worktree {
    case .none: "No worktree"
    case .new(let branch, _): "New branch: \(branch)"
    case .existing(let option): "Worktree: \(option.branch ?? option.path)"
    }
  }
}

/// The start options' actions. `nil` hides the control.
public struct NewSessionOptionActions {
  /// Choose a folder (absolute path).
  public var selectFolder: (@MainActor (String) -> Void)?
  /// Read a host folder for the browser: `nil` reads the home folder.
  public var browse: (@MainActor (String?) async -> Result<FolderListing, FolderBrowseError>)?
  /// Choose where in the repository the session works.
  public var selectWorktree: (@MainActor (NewSessionWorktreeChoice) -> Void)?
  /// Validate a new branch name.
  public var isValidBranch: (@MainActor (String) -> Bool)?
  /// Edit the sandbox repositories.
  public var repositories: SandboxRepositoriesActions?
  /// Choose the sandbox profile.
  public var profiles: SandboxProfilesActions?
  /// Open the harness setup sheet from the not-ready notice.
  public var setUpHarness: (@MainActor () -> Void)?
  /// Open Connect a Host from the no-host notice.
  public var connectHost: (@MainActor () -> Void)?
  /// Choose the project by name (`nil` for none).
  public var selectProject: (@MainActor (String?) -> Void)?

  /// Creates actions.
  /// - Parameters:
  ///   - selectFolder: Choose a folder.
  ///   - browse: Read a host folder.
  ///   - selectWorktree: Choose a worktree.
  ///   - isValidBranch: Branch validation.
  ///   - repositories: Sandbox repositories.
  ///   - profiles: Sandbox profile.
  ///   - setUpHarness: Open the harness setup sheet.
  public init(
    selectFolder: (@MainActor (String) -> Void)? = nil,
    browse: (@MainActor (String?) async -> Result<FolderListing, FolderBrowseError>)? = nil,
    selectWorktree: (@MainActor (NewSessionWorktreeChoice) -> Void)? = nil,
    isValidBranch: (@MainActor (String) -> Bool)? = nil,
    repositories: SandboxRepositoriesActions? = nil,
    profiles: SandboxProfilesActions? = nil,
    setUpHarness: (@MainActor () -> Void)? = nil
  ) {
    self.selectFolder = selectFolder
    self.browse = browse
    self.selectWorktree = selectWorktree
    self.isValidBranch = isValidBranch
    self.repositories = repositories
    self.profiles = profiles
    self.setUpHarness = setUpHarness
  }
}

/// The folder, worktree and repository chips under the new-session composer.
struct NewSessionOptionsBar: View {
  let options: NewSessionOptions
  let actions: NewSessionOptionActions

  @State private var isBrowsing = false
  @State private var isChoosingRepositories = false
  @State private var isNamingBranch = false
  @State private var branch = ""
  @State private var base = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      if options.needsHost {
        hostNoticeRow
      }
      if let notice = options.harnessNotice {
        harnessNoticeRow(notice)
      }
      HStack(spacing: Theme.Spacing.small) {
        if options.isSandbox {
          repositoriesChip
          if let profiles = options.profiles, let profileActions = actions.profiles {
            SandboxProfilePicker(state: profiles, actions: profileActions)
          }
        } else {
          folderMenu
          if options.offersWorktrees, actions.selectWorktree != nil {
            worktreeMenu
          }
        }
        if let selectProject = actions.selectProject,
          !options.projects.isEmpty || options.project != nil
        {
          NewSessionProjectMenu(
            project: options.project, projects: options.projects, select: selectProject)
        }
        if options.isPlanMode {
          Label("Plan mode", systemImage: "doc.text")
            .accessibilityIdentifier("new-session-plan-mode")
        }
        Spacer(minLength: 0)
      }
    }
    .font(.callout)
    .menuStyle(.button)
    .buttonStyle(.borderless)
    // The chips are settings, not links: neutral as the composer's, never system blue.
    .tint(.secondary)
    .sheet(isPresented: $isBrowsing) {
      if let browse = actions.browse {
        FolderBrowserView(
          initialPath: options.folder, load: browse,
          choose: { path in
            actions.selectFolder?(path)
            isBrowsing = false
          },
          cancel: { isBrowsing = false })
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("new-session-options")
  }

  /// The amber line for a server with nowhere to run agents, and the way to fix it.
  private var hostNoticeRow: some View {
    HStack(spacing: Theme.Spacing.small) {
      Label(
        "No host is connected, so agents can't run yet.",
        systemImage: "exclamationmark.triangle.fill"
      )
      .foregroundStyle(Theme.warning)
      if let connect = actions.connectHost {
        Button("Connect a Host\u{2026}", action: connect)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(Theme.warning)
          .accessibilityIdentifier("new-session-connect-host")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("new-session-host-notice")
  }

  /// The web's amber "not ready" line with its Set Up button.
  private func harnessNoticeRow(_ notice: String) -> some View {
    HStack(spacing: Theme.Spacing.small) {
      Label(notice, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(Theme.warning)
      if let setUp = actions.setUpHarness {
        Button("Set Up \(options.setUpName ?? "Agent")\u{2026}", action: setUp)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(Theme.warning)
          .accessibilityIdentifier("new-session-harness-setup")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("new-session-harness-notice")
  }

  private var folderMenu: some View {
    Menu {
      // First, so a host with many folders cannot scroll it out of the menu.
      if actions.browse != nil {
        Button("Browse Folders\u{2026}", systemImage: "folder.badge.gearshape") {
          isBrowsing = true
        }
        .accessibilityIdentifier("new-session-browse-folders")
      }
      if !options.recentFolders.isEmpty {
        Section("Folders") {
          ForEach(options.recentFolders, id: \.self) { path in
            Button(path) { actions.selectFolder?(path) }
          }
        }
      }
    } label: {
      Label(
        options.folder.map { URL(filePath: $0).lastPathComponent } ?? "Choose folder",
        systemImage: "folder")
    }
    .fixedSize()
    .help(options.folder ?? "Choose the folder the session works in")
    .accessibilityLabel("Folder, \(options.folder ?? "none")")
    .accessibilityIdentifier("new-session-folder")
  }

  private var worktreeMenu: some View {
    Menu {
      Button("No worktree") { actions.selectWorktree?(.none) }
      Button("New Worktree\u{2026}", systemImage: "plus") {
        if case .new(let current, let currentBase) = options.worktree {
          branch = current
          base = currentBase
        } else if base.isEmpty {
          base = options.defaultBaseBranch.trimmingCharacters(in: .whitespaces)
        }
        isNamingBranch = true
      }
      if !options.worktrees.isEmpty {
        Section("Existing worktrees") {
          ForEach(options.worktrees) { option in
            Button(option.branch ?? URL(filePath: option.path).lastPathComponent) {
              actions.selectWorktree?(.existing(option))
            }
          }
        }
      }
    } label: {
      Label(options.worktreeTitle, systemImage: "arrow.triangle.branch")
    }
    .fixedSize()
    .help("Work in the folder, a new worktree branch, or an existing worktree")
    .accessibilityIdentifier("new-session-worktree")
    .popover(isPresented: $isNamingBranch) { branchForm }
  }

  private var isBranchValid: Bool {
    let name = branch.trimmingCharacters(in: .whitespaces)
    return actions.isValidBranch?(name) ?? !name.isEmpty
  }

  private var branchForm: some View {
    Form {
      TextField("Branch", text: $branch, prompt: Text("feature/my-change"))
        .accessibilityIdentifier("new-session-branch")
      TextField("From", text: $base, prompt: Text("Default branch"))
        .accessibilityIdentifier("new-session-base-branch")
      HStack {
        Spacer()
        Button("Cancel") { isNamingBranch = false }
        Button("Use Branch") {
          actions.selectWorktree?(
            .new(
              branch: branch.trimmingCharacters(in: .whitespaces),
              base: base.trimmingCharacters(in: .whitespaces)))
          isNamingBranch = false
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!isBranchValid)
      }
    }
    .padding()
    .frame(width: 320)
  }

  /// The web's repository chip: the chosen repositories, opening the picker.
  @ViewBuilder private var repositoriesChip: some View {
    if let repositoryActions = actions.repositories {
      let label = options.repositories.label(name: repositoryActions.repoName)
      Button {
        isChoosingRepositories = true
      } label: {
        Label(label, systemImage: "arrow.triangle.branch")
      }
      .fixedSize()
      .foregroundStyle(options.repositories.problem == nil ? .primary : Theme.warning)
      .help(options.repositories.problem ?? "Repositories cloned into the sandbox")
      .accessibilityLabel("Sandbox repositories, \(label)")
      .accessibilityIdentifier("new-session-repositories")
      .popover(isPresented: $isChoosingRepositories) {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          Text("Repositories (optional)").font(.headline)
          SandboxRepositoriesEditor(state: options.repositories, actions: repositoryActions)
        }
        .padding()
        .frame(width: 400)
      }
    }
  }
}
